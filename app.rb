# frozen_string_literal: true

require 'bundler/setup'
require 'json'
require 'uri'
require 'time'
require 'rack/utils'
require 'rack/mime'
require 'sinatra/base'
require 'sinatra/json'
require 'securerandom'

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
      session_secret = MyS3.config[:session_secret].to_s.strip
      session_secret = SecureRandom.hex(32) if session_secret.empty?
      set :sessions, key: 'mys3.session',
                     secret: session_secret,
                     same_site: :strict,
                     httponly: true
    end

    before do
      if html_ui_request? || public_file_request?
        @public_request = true
        next
      end

      content_type :json
      authenticate_request!
    end
    get '/' do
      content_type :html
      if authorized_session?
        path = params['path'].to_s
        notice = params['notice']
        error_message = params['error']
        begin
          listing = storage.list(path)
        rescue StorageError => e
          error_message = [error_message, e.message].compact.join(' • ')
          listing = storage.list('')
        end
        render_browser_page(listing: listing, notice: notice, error: error_message)
      else
        render_login_page(error: params['error'])
      end
    end

    helpers do
      def storage
        settings.storage
      end

      def html_ui_request?
        ui_paths = ['/', '/logout']
        ui_paths.include?(request.path_info) || request.path_info.start_with?('/ui/')
      end

      def session_api_key
        session[:api_key]
      end

      def store_session_api_key(value)
        session[:api_key] = value
      end

      def clear_session_api_key
        session.delete(:api_key)
      end

      def authorized_session?
        key = session_api_key.to_s
        return false if key.empty?

        secure_compare(key, settings.api_key)
      end

      def require_session_auth!
        return if authorized_session?

        redirect '/'
      end

      def ui_redirect_path(path:, notice: nil, error: nil)
        query = {}
        query[:path] = path unless path.to_s.empty?
        query[:notice] = notice if notice
        query[:error] = error if error
        qs = Rack::Utils.build_query(query)
        qs.empty? ? '/' : "/?#{qs}"
      end

      def h(value)
        Rack::Utils.escape_html(value.to_s)
      end

      def human_size(bytes)
        units = %w[B KB MB GB TB]
        size = bytes.to_f
        index = 0
        while size >= 1024 && index < units.length - 1
          size /= 1024.0
          index += 1
        end
        format('%.2f %s', size, units[index])
      end

      def inline_view_href(relative_file_path)
        segments = relative_file_path.to_s.split('/').reject(&:empty?).map do |segment|
          Rack::Utils.escape_path(segment)
        end
        "/#{segments.join('/')}"
      end

      def breadcrumbs_for(path)
        segments = path.to_s.split('/').reject(&:empty?)
        crumbs = [{ name: 'Storage Root', path: '' }]
        segments.each_with_index do |segment, index|
          crumb_path = segments[0..index].join('/')
          crumbs << { name: segment, path: crumb_path }
        end
        crumbs
      end

      def render_login_page(error: nil)
        <<~HTML
          <!doctype html>
          <html lang="en">
          <head>
            <meta charset="utf-8">
            <title>MyS3</title>
            <style>
              @import url('https://fonts.googleapis.com/css2?family=Space+Grotesk:wght@400;600&display=swap');
              :root {
                color-scheme: dark;
                --bg: radial-gradient(circle at top, #172554, #020617 70%);
                --panel: rgba(15, 23, 42, 0.85);
                --accent: #38bdf8;
                --accent-strong: #0ea5e9;
                --muted: #94a3b8;
                --error: #f87171;
              }
              * { box-sizing: border-box; }
              body {
                font-family: 'Space Grotesk', sans-serif;
                min-height: 100vh;
                margin: 0;
                display: flex;
                align-items: center;
                justify-content: center;
                background: var(--bg);
                color: #e2e8f0;
              }
              .card {
                width: min(420px, 90vw);
                background: var(--panel);
                border-radius: 1.2rem;
                padding: 2.5rem;
                box-shadow: 0 20px 45px rgba(2, 6, 23, 0.75);
              }
              h1 { margin-top: 0; font-size: 2rem; }
              p { color: var(--muted); }
              .error {
                background: rgba(248, 113, 113, 0.15);
                border: 1px solid rgba(248, 113, 113, 0.7);
                border-radius: 0.75rem;
                padding: 0.75rem 1rem;
                margin-bottom: 1.5rem;
                color: var(--error);
              }
              form { display: flex; flex-direction: column; gap: 1rem; margin-top: 1.5rem; }
              label { font-size: 0.95rem; color: var(--muted); }
              input[type="password"], input[type="text"] {
                width: 100%;
                padding: 0.85rem 1rem;
                border-radius: 0.8rem;
                border: 1px solid rgba(148, 163, 184, 0.4);
                background: rgba(15, 23, 42, 0.6);
                color: #f8fafc;
              }
              button {
                border: none;
                border-radius: 999px;
                padding: 0.95rem;
                font-size: 1rem;
                font-weight: 600;
                background: linear-gradient(120deg, var(--accent), var(--accent-strong));
                color: #0f172a;
                cursor: pointer;
                transition: transform 0.2s ease, box-shadow 0.2s ease;
              }
              button:hover { transform: translateY(-2px); box-shadow: 0 10px 25px rgba(14, 165, 233, 0.35); }
            </style>
          </head>
          <body>
            <section class="card">
              <h1>Unlock MyS3</h1>
              <p>Enter the API key to explore your storage.</p>
              #{error ? "<div class=\"error\">#{h(error)}</div>" : ''}
              <form method="post" action="/">
                <label for="api_key">API Key</label>
                <input id="api_key" type="password" name="api_key" autocomplete="current-password" required>
                <button type="submit">Start Browsing</button>
              </form>
            </section>
          </body>
          </html>
        HTML
      end

      def render_browser_page(listing:, notice: nil, error: nil)
        current_path = listing[:path]
        crumbs = breadcrumbs_for(current_path)
        notices = []
        notices << { type: :notice, message: notice } if notice
        notices << { type: :error, message: error } if error
        directories = listing[:directories].map do |dir|
          href = "/?#{Rack::Utils.build_query(path: dir[:path])}"
          <<~HTML
            <div class="entry">
              <div>
                <span class="pill">Folder</span>
                <a href="#{href}">#{h(dir[:name])}</a>
                <p class="muted">Updated #{h(dir[:modified_at])}</p>
              </div>
              <form method="post" action="/ui/delete_folder" onsubmit="return confirm('Delete this folder?')">
                <input type="hidden" name="target_path" value="#{h(dir[:path])}">
                <input type="hidden" name="current_path" value="#{h(current_path)}">
                <button type="submit" class="danger">Delete</button>
              </form>
            </div>
          HTML
        end.join

        files = listing[:files].map do |file|
          inline_href = inline_view_href(file[:path])
          download_href = "/ui/download_file?#{Rack::Utils.build_query(path: current_path, filename: file[:name])}"
          <<~HTML
            <div class="entry">
              <div>
                <span class="pill file">File</span>
                <strong>#{h(file[:name])}</strong>
                <p class="muted">#{human_size(file[:size_bytes])} • Updated #{h(file[:modified_at])}</p>
              </div>
              <div class="actions">
                <a class="ghost" href="#{download_href}">Download</a>
                <a class="ghost" href="#{inline_href}" target="_blank" rel="noopener">Open</a>
                <form method="post" action="/ui/delete_file" onsubmit="return confirm('Delete this file?')">
                  <input type="hidden" name="path" value="#{h(current_path)}">
                  <input type="hidden" name="filename" value="#{h(file[:name])}">
                  <button type="submit" class="danger">Delete</button>
                </form>
              </div>
            </div>
          HTML
        end.join

        notices_html = notices.map do |flash|
          css = flash[:type] == :notice ? 'flash notice' : 'flash error'
          "<div class=\"#{css}\">#{h(flash[:message])}</div>"
        end.join

        breadcrumbs_html = crumbs.map do |crumb|
          href = crumb[:path] == current_path ? nil : "/?#{Rack::Utils.build_query(path: crumb[:path])}"
          href ? "<a href=\"#{href}\">#{h(crumb[:name])}</a>" : "<span>#{h(crumb[:name])}</span>"
        end.join('<span class="crumb-sep">/</span>')

        <<~HTML
          <!doctype html>
          <html lang="en">
          <head>
            <meta charset="utf-8">
            <title>MyS3 Browser</title>
            <style>
              @import url('https://fonts.googleapis.com/css2?family=Space+Grotesk:wght@400;600&display=swap');
              :root {
                color-scheme: dark;
                --bg: linear-gradient(135deg, #020617, #0f172a 55%, #312e81);
                --panel: rgba(15, 23, 42, 0.85);
                --muted: #94a3b8;
                --border: rgba(148, 163, 184, 0.2);
                --accent: #38bdf8;
                --danger: #f87171;
              }
              * { box-sizing: border-box; }
              body {
                margin: 0;
                min-height: 100vh;
                font-family: 'Space Grotesk', sans-serif;
                background: var(--bg);
                color: #e2e8f0;
                display: flex;
                flex-direction: column;
                align-items: center;
                padding: 2rem clamp(1rem, 4vw, 3.5rem);
              }
              main {
                width: min(1100px, 100%);
                background: var(--panel);
                border-radius: 1.5rem;
                padding: clamp(1.5rem, 3vw, 2.75rem);
                box-shadow: 0 30px 60px rgba(2, 6, 23, 0.65);
              }
              header { display: flex; justify-content: space-between; align-items: center; flex-wrap: wrap; gap: 1rem; }
              h1 { margin: 0; font-size: clamp(1.5rem, 3vw, 2.4rem); }
              .logout button {
                background: transparent;
                border: 1px solid var(--border);
                border-radius: 999px;
                color: #f1f5f9;
                padding: 0.6rem 1.5rem;
                cursor: pointer;
                transition: border-color 0.2s ease;
              }
              .logout button:hover { border-color: var(--danger); color: var(--danger); }
              .breadcrumbs { margin: 1.5rem 0; display: flex; flex-wrap: wrap; gap: 0.5rem; align-items: center; color: var(--muted); }
              .breadcrumbs a { color: var(--accent); text-decoration: none; }
              .crumb-sep { color: var(--border); }
              .flash { padding: 0.85rem 1rem; border-radius: 0.9rem; margin-bottom: 1rem; }
              .flash.notice { background: rgba(56, 189, 248, 0.18); border: 1px solid rgba(56, 189, 248, 0.4); }
              .flash.error { background: rgba(248, 113, 113, 0.18); border: 1px solid rgba(248, 113, 113, 0.4); }
              section { margin-top: 2rem; }
              .entry { display: flex; justify-content: space-between; align-items: center; padding: 1rem 0; border-bottom: 1px solid var(--border); gap: 1rem; }
              .entry:last-child { border-bottom: none; }
              .entry strong, .entry a { font-size: 1rem; }
              .entry a { color: #f8fafc; text-decoration: none; }
              .muted { color: var(--muted); margin: 0.2rem 0 0; font-size: 0.9rem; }
              .pill { display: inline-flex; align-items: center; gap: 0.35rem; font-size: 0.75rem; text-transform: uppercase; letter-spacing: 0.08em; color: var(--muted); border: 1px solid var(--border); border-radius: 999px; padding: 0.15rem 0.75rem; margin-right: 0.5rem; }
              .pill.file { border-color: rgba(248, 250, 252, 0.2); }
              form { margin: 0; }
              .actions { display: flex; align-items: center; gap: 0.5rem; flex-wrap: wrap; justify-content: flex-end; }
              .ghost {
                border: 1px solid rgba(148, 163, 184, 0.4);
                border-radius: 999px;
                padding: 0.3rem 0.9rem;
                color: #e2e8f0;
                text-decoration: none;
                font-size: 0.9rem;
                transition: border-color 0.2s ease, color 0.2s ease;
              }
              .ghost:hover { border-color: var(--accent); color: var(--accent); }
              button.danger {
                border: 1px solid rgba(248, 113, 113, 0.6);
                color: #fecaca;
                background: transparent;
                border-radius: 999px;
                padding: 0.35rem 1.1rem;
                cursor: pointer;
                transition: background 0.2s ease, color 0.2s ease;
              }
              button.danger:hover { background: rgba(248, 113, 113, 0.15); color: #fee2e2; }
            </style>
          </head>
          <body>
            <main>
              <header>
                <div>
                  <h1>MyS3 Browser</h1>
                  <p class="muted">#{current_path.empty? ? 'Browsing storage root' : h(current_path)}</p>
                </div>
                <form class="logout" method="post" action="/logout">
                  <button type="submit">Sign out</button>
                </form>
              </header>
              <div class="breadcrumbs">#{breadcrumbs_html}</div>
              #{notices_html}
              <section>
                <h2>Folders</h2>
                #{directories.empty? ? '<p class="muted">No folders here yet.</p>' : directories}
              </section>
              <section>
                <h2>Files</h2>
                #{files.empty? ? '<p class="muted">No files here yet.</p>' : files}
              </section>
            </main>
          </body>
          </html>
        HTML
      end

      def authenticate_request!
        provided_key = request.get_header('HTTP_X_API_KEY')
        unauthorized! unless secure_compare(provided_key.to_s, settings.api_key)
      end

      def public_file_request?
        (request.get? || request.head?) &&
          !request.path_info.end_with?('.json') &&
          request.path_info != '/'
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

      def json_response(data = nil, status_code: 200, **extra)
        if data.nil? && !extra.empty?
          data = extra
          extra = {}
        end

        payload = { success: true }
        payload.merge!(data) if data
        payload.merge!(extra) unless extra.empty?
        status status_code
        json(payload)
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

    get %r{/(.+)} do |relative_path|
      pass if relative_path.start_with?('ui/')
      begin
        absolute = storage.file_path(relative_path)
      rescue StorageError
        halt 404
      end

      cache_control :public, max_age: 3600
      content_type Rack::Mime.mime_type(File.extname(absolute), 'application/octet-stream')
      send_file absolute.to_s, disposition: 'inline'
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

    post '/' do
      api_key = params['api_key'].to_s.strip
      if secure_compare(api_key, settings.api_key)
        store_session_api_key(api_key)
        redirect '/'
      else
        clear_session_api_key
        redirect '/?error=Invalid+API+key'
      end
    end

    post '/logout' do
      clear_session_api_key
      redirect '/'
    end

    get '/ui/download_file' do
      require_session_auth!
      path = params['path'].to_s
      filename = params['filename'].to_s
      begin
        relative = storage.public_path(path, filename)
        absolute = storage.file_path(relative)
      rescue StorageError => e
        redirect ui_redirect_path(path: path, error: e.message)
      end

      send_file absolute.to_s,
                filename: filename,
                disposition: 'attachment',
                type: Rack::Mime.mime_type(File.extname(filename), 'application/octet-stream')
    end

    post '/ui/delete_file' do
      require_session_auth!
      path = params['path'].to_s
      filename = params['filename'].to_s
      begin
        storage.delete_file(path, filename)
        redirect ui_redirect_path(path: path, notice: "Deleted file #{filename}")
      rescue StorageError => e
        redirect ui_redirect_path(path: path, error: e.message)
      end
    end

    post '/ui/delete_folder' do
      require_session_auth!
      target_path = params['target_path'].to_s
      current_path = params['current_path'].to_s
      begin
        storage.delete_folder(target_path)
        folder_name = File.basename(target_path.to_s)
        redirect ui_redirect_path(path: current_path, notice: "Deleted folder #{folder_name}")
      rescue StorageError => e
        redirect ui_redirect_path(path: current_path, error: e.message)
      end
    end

    run! if app_file == $PROGRAM_NAME
  end
end
