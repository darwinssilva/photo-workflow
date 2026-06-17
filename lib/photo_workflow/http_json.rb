require "json"
require "net/http"
require "uri"

module PhotoWorkflow
  class HttpJson
    def self.get(url, headers: {})
      request(Net::HTTP::Get, url, headers: headers)
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

    def self.put(url, query: {})
      uri = URI(url)
      uri.query = URI.encode_www_form(query)
      request(Net::HTTP::Put, uri)
    end

    def self.request(klass, url, headers: {})
      uri = url.is_a?(URI) ? url : URI(url)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = uri.scheme == "https"

      request = klass.new(uri)
      headers.each { |key, value| request[key] = value }

      parse_response(http.request(request))
    end

    def self.parse_response(response)
      body = response.body.to_s
      parsed = body.empty? ? {} : JSON.parse(body)

      return parsed if response.is_a?(Net::HTTPSuccess)

      raise "HTTP #{response.code}: #{parsed}"
    rescue JSON::ParserError
      raise "HTTP #{response.code}: #{body}"
    end
  end
end

