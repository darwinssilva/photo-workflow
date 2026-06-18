require "json"
require "net/http"
require "uri"

module PhotoWorkflow
  class HttpJson
    class Error < StandardError
      attr_reader :code, :body

      def initialize(code, body)
        @code = code.to_i
        @body = body
        super("HTTP #{code}: #{body}")
      end
    end

    def self.get(url, headers: {}, query: {})
      uri = url.is_a?(URI) ? url : URI(url)
      uri.query = URI.encode_www_form(query) unless query.empty?
      request(Net::HTTP::Get, uri, headers: headers)
    end

    def self.post_form(url, form:)
      uri = URI(url)
      response = Net::HTTP.post_form(uri, form)
      parse_response(response)
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

      request = klass.new(uri)
      headers.each { |key, value| request[key] = value }
      request.body = body if body

      parse_response(http.request(request))
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
