require "date"
require "time"
require "uri"

require_relative "http_json"

module PhotoWorkflow
  class GoogleCalendarClient
    TOKEN_URL = "https://oauth2.googleapis.com/token"
    EVENTS_URL = "https://www.googleapis.com/calendar/v3/calendars/%<calendar_id>s/events"

    def upcoming_events(days_ahead: env_integer("DAYS_AHEAD", 180))
      url = URI(format(EVENTS_URL, calendar_id: URI.encode_www_form_component(required_env("GOOGLE_CALENDAR_ID"))))
      url.query = URI.encode_www_form(
        singleEvents: true,
        orderBy: "startTime",
        maxResults: 250,
        timeMin: today_start.utc.iso8601,
        timeMax: (Time.now.utc + days_ahead * 24 * 60 * 60).iso8601
      )

      response = HttpJson.get(url, headers: { "Authorization" => "Bearer #{access_token}" })
      response.fetch("items", [])
    end

    private

    def access_token
      response = HttpJson.post_form(
        TOKEN_URL,
        form: {
          client_id: required_env("GOOGLE_CLIENT_ID"),
          client_secret: required_env("GOOGLE_CLIENT_SECRET"),
          refresh_token: required_env("GOOGLE_REFRESH_TOKEN"),
          grant_type: "refresh_token"
        }
      )

      response.fetch("access_token")
    end

    def required_env(name)
      ENV.fetch(name) { raise "Missing ENV #{name}" }
    end

    def env_integer(name, fallback)
      ENV.fetch(name, fallback).to_i
    end

    def today_start
      Time.local(Time.now.year, Time.now.month, Time.now.day)
    end
  end
end
