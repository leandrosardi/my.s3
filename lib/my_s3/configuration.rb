# frozen_string_literal: true

require 'yaml'
require 'pathname'
require 'logger'
require 'fileutils'

module MyS3
  class ConfigurationError < StandardError; end

  DEFAULTS = {
    max_upload_size_mb: 100,
    follow_symlinks: false,
    puma_threads_min: 4,
    puma_threads_max: 16,
    log_level: 'info',
    log_file: 'log/app.log',
    timezone: 'UTC'
  }.freeze

  REQUIRED_KEYS = %i[api_key storage_root public_base_url bind_host port].freeze

  class << self
    attr_reader :config, :logger

    def load_config!(path)
      config_path = Pathname.new(path).expand_path
      raise ConfigurationError, "Configuration file not found: #{config_path}" unless config_path.file?

      raw = YAML.safe_load(config_path.read, permitted_classes: [], aliases: false) || {}
      symbolized = symbolize_keys(raw)
      merged = DEFAULTS.merge(symbolized)

      REQUIRED_KEYS.each do |key|
        value = merged[key]
        raise ConfigurationError, "Missing configuration key: #{key}" if value.nil? || value.to_s.strip.empty?
      end

      config_dir = config_path.dirname
      merged[:storage_root] = absolute_path(merged[:storage_root], config_dir)
      FileUtils.mkdir_p(merged[:storage_root])

      merged[:log_file] = absolute_path(merged[:log_file], config_dir) if merged[:log_file]
      merged[:public_base_url] = merged[:public_base_url].to_s.chomp('/').strip
      merged[:max_upload_size_bytes] = merged[:max_upload_size_mb].to_i * 1024 * 1024
      merged[:follow_symlinks] = !!merged[:follow_symlinks]
      merged[:bind_host] = merged[:bind_host].to_s
      merged[:port] = Integer(merged[:port])
      merged[:puma_threads_min] = Integer(merged[:puma_threads_min])
      merged[:puma_threads_max] = Integer(merged[:puma_threads_max])
      if merged[:puma_threads_min] <= 0 || merged[:puma_threads_max] <= 0
        raise ConfigurationError, 'Puma thread counts must be positive integers'
      end
      if merged[:puma_threads_min] > merged[:puma_threads_max]
        raise ConfigurationError, 'puma_threads_min cannot exceed puma_threads_max'
      end

      @config = merged.freeze
      apply_timezone
      setup_logger
      @config
    end

    private

    def setup_logger
      level = level_from_string(config[:log_level])
      log_target = config[:log_file]

      if log_target && !log_target.empty?
        FileUtils.mkdir_p(File.dirname(log_target))
        log_io = File.open(log_target, 'a')
        log_io.sync = true
        @logger = Logger.new(log_io)
      else
        @logger = Logger.new($stdout)
      end

      @logger.level = level
      @logger.progname = 'MyS3'
    end

    def apply_timezone
      tz = config[:timezone]
      return if tz.nil? || tz.to_s.strip.empty?

      ENV['TZ'] = tz
    end

    def symbolize_keys(hash)
      hash.each_with_object({}) do |(k, v), acc|
        key = k.respond_to?(:to_sym) ? k.to_sym : k
        acc[key] = v.is_a?(Hash) ? symbolize_keys(v) : v
      end
    end

    def absolute_path(value, base)
      path = Pathname.new(value.to_s)
      path.absolute? ? path.expand_path.to_s : base.join(path).expand_path.to_s
    end

    def level_from_string(value)
      case value.to_s.downcase
      when 'debug' then Logger::DEBUG
      when 'warn' then Logger::WARN
      when 'error' then Logger::ERROR
      when 'fatal' then Logger::FATAL
      else Logger::INFO
      end
    end
  end
end
