# frozen_string_literal: true

require 'bundler/setup'
require 'json'
require 'uri'
require 'time'
require 'rack/utils'
require 'sinatra/base'
require 'sinatra/json'

require_relative 'lib/my_s3/configuration'
require_relative 'lib/my_s3/storage'

config_path = ENV.fetch('MY_S3_CONFIG', File.expand_path('config.yml', __dir__))
MyS3.load_config!(config_path)
STORAGE = MyS3::Storage.new(
  root: MyS3.config[:storage_root],
  follow_symlinks: MyS3.config[:follow_symlinks]
)

module MyS3
  class App < Sinatra::Base
    configure do
      set :bind, MyS3.config[:bind_host]
      set :port, MyS3.config[:port]
      set :threaded, true
      set :logging, false
      set :show_exceptions, false
      set :raise_errors, false
      set :storage, STORAGE
      set :api_key, MyS3.config[:api_key]
      set :public_base_url, MyS3.config[:public_base_url]
      set :max_upload_size_bytes, MyS3.config[:max_upload_size_bytes]
    end

    before do
      content_type :json
      authenticate_request!
    end

    helpers do
      def storage
        settings.storage
      end

      def authenticate_request!
        provided_key = request.get_header('HTTP_X_API_KEY')
        unauthorized! unless secure_compare(provided_key.to_s, settings.api_key)
      end

      def secure_compare(given, actual)
        return false if given.nil? || actual.nil? || given.bytesize != actual.bytesize

        Rack::Utils.secure_compare(given, actual)
      rescue Rack::Utils::InvalidParameterError
        false
      end

      def request_payload
        return @request_payload if defined?(@request_payload)

        if request.media_type == 'application/json'
          body = request.body.read
          request.body.rewind
          @request_payload = body.nil? || body.empty? ? {} : JSON.parse(body)
        else
          @request_payload = {}
        end
      rescue JSON::ParserError
        halt_error 400, 'Invalid JSON payload'
      end

      def param_value(name, required: false, default: nil, allow_empty: false)
        key = name.to_s
        value = params.key?(key) ? params[key] : request_payload[key]
        value = default if value.nil?

        if !allow_empty && value.respond_to?(:strip)
          value = value.strip
        end

        if required && (value.nil? || (!allow_empty && value.to_s.empty?))
          halt_error 422, "Missing parameter: #{name}"
        end

        value
      end

      def parsed_path
        param_value('path', default: '', allow_empty: true) || ''
      end

      def halt_error(status_code, message, extra = {})
        status status_code
        payload = { success: false, error: { message: message } }
        payload[:error][:details] = extra unless extra.empty?
        body JSON.generate(payload)
        halt
      end

      def unauthorized!
        halt_error 401, 'Invalid or missing API key'
      end

      def json_response(data = {}, status_code: 200)
        status status_code
        json({ success: true }.merge(data))
      end

      def enforce_upload_limit!(file)
        limit = settings.max_upload_size_bytes.to_i
        return if limit <= 0

        size = file.size
        halt_error 413, 'File exceeds maximum allowed size' if size > limit
      end

      def build_public_url(relative_path)
        base = settings.public_base_url
        return base if relative_path.to_s.empty?

        base = base.end_with?('/') ? base : "#{base}/"
        joined = relative_path.gsub(%r{^/+}, '')
        # Preserve protocol double slashes while collapsing others
        (base + joined).gsub(%r{(?<!:)//+}, '/')
      end
    end

    get '/list.json' do
      path = parsed_path
      payload = storage.list(path)
      json_response(payload)
    rescue StorageError => e
      halt_error 400, e.message
    end

    post '/create_folder.json' do
      path = parsed_path
      folder_name = param_value('folder_name', required: true)
      metadata = storage.create_folder(path, folder_name)
      json_response({ folder: metadata }, status_code: 201)
    rescue StorageError => e
      halt_error 400, e.message
    end

    delete '/delete_folder.json' do
      path = param_value('path', required: true)
      result = storage.delete_folder(path)
      json_response(result)
    rescue StorageError => e
      halt_error 400, e.message
    end

    post '/rename_folder.json' do
      path = param_value('path', required: true)
      new_name = param_value('new_name', required: true)
      metadata = storage.rename_folder(path, new_name)
      json_response(folder: metadata)
    rescue StorageError => e
      halt_error 400, e.message
    end

    post '/upload.json' do
      halt_error 415, 'upload.json expects multipart/form-data' unless request.media_type&.include?('multipart/form-data')

      path = parsed_path
      file_param = params['file']
      halt_error 422, 'File parameter is required' unless file_param && file_param[:tempfile]

      tempfile = file_param[:tempfile]
      enforce_upload_limit!(tempfile)
      metadata = storage.upload_file(path, tempfile, file_param[:filename])
      json_response({ file: metadata }, status_code: 201)
    rescue StorageError => e
      halt_error 400, e.message
    end

    delete '/delete.json' do
      path = param_value('path', required: true)
      filename = param_value('filename', required: true)
      result = storage.delete_file(path, filename)
      json_response(result)
    rescue StorageError => e
      halt_error 400, e.message
    end

    post '/delete_older_than.json' do
      path = param_value('path', required: true, allow_empty: true)
      older_than = param_value('older_than', required: true)
      threshold = Time.iso8601(older_than)
      result = storage.delete_older_than(path, threshold)
      json_response(result)
    rescue ArgumentError
      halt_error 422, 'older_than must be a valid ISO 8601 timestamp'
    rescue StorageError => e
      halt_error 400, e.message
    end

    post '/get_download_url.json' do
      path = param_value('path', required: true, allow_empty: true)
      filename = param_value('filename', required: true)
      relative = storage.public_path(path, filename)
      json_response(download_url: build_public_url(relative))
    rescue StorageError => e
      halt_error 400, e.message
    end

    post '/get_public_url.json' do
      path = param_value('path', required: true, allow_empty: true)
      filename = param_value('filename', required: true)
      relative = storage.public_path(path, filename)
      json_response(public_url: build_public_url(relative))
    rescue StorageError => e
      halt_error 400, e.message
    end

    error StorageError do
      err = env['sinatra.error']
      MyS3.logger&.warn(err.message)
      halt_error 400, err.message
    end

    error do
      err = env['sinatra.error']
      MyS3.logger&.error(err&.full_message || 'Unhandled error')
      halt_error 500, 'Internal server error'
    end

    not_found do
      halt_error 404, 'Endpoint not found'
    end

    run! if app_file == $PROGRAM_NAME
  end
end
