require "json"
require "net/http"
require "timeout"
require "uri"

module PhotoWorkflow
  class HttpJson
    DEFAULT_OPEN_TIMEOUT = 10
    DEFAULT_READ_TIMEOUT = 30
    DEFAULT_RETRIES = 2

    class Error < StandardError
      attr_reader :code, :body

      def initialize(code, body)
        @code = code.to_i
        @body = body
        super("HTTP #{code}: #{body}")
      end
    end

    class ConnectionError < StandardError; end

    def self.get(url, headers: {}, query: {})
      uri = url.is_a?(URI) ? url : URI(url)
      uri.query = URI.encode_www_form(query) unless query.empty?
      request(Net::HTTP::Get, uri, headers: headers)
    end

    def self.post_form(url, form:)
      request(
        Net::HTTP::Post,
        url,
        headers: { "Content-Type" => "application/x-www-form-urlencoded" },
        body: URI.encode_www_form(form)
      )
    end

    def self.post(url, query: {})
      uri = URI(url)
      uri.query = URI.encode_www_form(query)
      request(Net::HTTP::Post, uri)
    end

    def self.post_json(url, body:, headers: {})
      request(Net::HTTP::Post, url, headers: headers.merge(
        "Content-Type" => "application/json"
      ), body: JSON.generate(body))
    end

    def self.put(url, query: {})
      uri = URI(url)
      uri.query = URI.encode_www_form(query)
      request(Net::HTTP::Put, uri)
    end

    def self.request(klass, url, headers: {}, body: nil)
      uri = url.is_a?(URI) ? url : URI(url)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = uri.scheme == "https"
      http.open_timeout = env_integer("HTTP_OPEN_TIMEOUT", DEFAULT_OPEN_TIMEOUT)
      http.read_timeout = env_integer("HTTP_READ_TIMEOUT", DEFAULT_READ_TIMEOUT)

      request = klass.new(uri)
      headers.each { |key, value| request[key] = value }
      request.body = body if body

      parse_response(with_retries(uri) { http.request(request) })
    end

    def self.with_retries(uri)
      attempts = env_integer("HTTP_RETRIES", DEFAULT_RETRIES)
      current_attempt = 0

      begin
        current_attempt += 1
        yield
      rescue Net::OpenTimeout, Net::ReadTimeout, Timeout::Error, EOFError, Errno::ECONNRESET, Errno::ETIMEDOUT, SocketError => error
        retry if current_attempt <= attempts

        raise ConnectionError, "Connection to #{uri.host}:#{uri.port} failed after #{current_attempt} attempt(s): #{error.class} - #{error.message}"
      end
    end

    def self.env_integer(name, fallback)
      ENV.fetch(name, fallback).to_i
    end

    def self.parse_response(response)
      body = response.body.to_s
      parsed = body.empty? ? {} : JSON.parse(body)

      return parsed if response.is_a?(Net::HTTPSuccess)

      raise Error.new(response.code, parsed)
    rescue JSON::ParserError
      raise Error.new(response.code, body)
    end
  end
end
