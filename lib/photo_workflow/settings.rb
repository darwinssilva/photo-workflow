require "json"

module PhotoWorkflow
  module Settings
    ROOT_PATH = File.expand_path("../..", __dir__)
    DEFAULT_CONFIG_PATH = File.join(ROOT_PATH, "config", "settings.json")
    DEFAULT_ENV_PATH = File.join(ROOT_PATH, ".env")

    module_function

    def value(name, fallback = nil)
      load!
      key = name.to_s
      env_value = ENV[key]
      return env_value unless blank_string?(env_value)

      config_value = config.fetch(key, nil)
      return config_value unless blank_string?(config_value)

      fallback
    end

    def required(name)
      found = value(name)
      raise "Missing setting #{name}" if blank_string?(found)

      found
    end

    def integer(name, fallback)
      value(name, fallback).to_i
    end

    def boolean(name, fallback = false)
      raw = value(name, fallback)
      return raw if raw == true || raw == false

      raw.to_s.casecmp("true").zero?
    end

    def load!
      return if @loaded

      load_env_file(DEFAULT_ENV_PATH)
      load_env_file(File.join(ROOT_PATH, "config", ".env"))
      @config = load_config_file(config_path)
      @loaded = true
    end

    def config
      @config ||= {}
    end

    def config_path
      ENV.fetch("PHOTO_WORKFLOW_CONFIG", DEFAULT_CONFIG_PATH)
    end

    def load_env_file(path)
      return unless File.exist?(path)

      File.readlines(path, chomp: true).each do |line|
        next if line.empty? || line.start_with?("#") || !line.include?("=")

        key, raw_value = line.split("=", 2)
        ENV[key] ||= unquote(raw_value.to_s.strip)
      end
    end

    def load_config_file(path)
      return {} unless File.exist?(path)

      JSON.parse(File.read(path))
    rescue JSON::ParserError => error
      raise "Invalid config file #{path}: #{error.message}"
    end

    def unquote(value)
      value.gsub(/\A(["'])(.*)\1\z/, "\\2")
    end

    def blank_string?(value)
      value.nil? || value.to_s.strip.empty?
    end
  end
end
