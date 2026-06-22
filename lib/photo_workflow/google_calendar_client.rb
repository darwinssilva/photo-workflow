require "date"
require "time"
require "uri"

require_relative "http_json"
require_relative "settings"

module PhotoWorkflow
  class GoogleCalendarClient
    class SyncTokenExpired < StandardError; end

    TOKEN_URL = "https://oauth2.googleapis.com/token"
    EVENTS_URL = "https://www.googleapis.com/calendar/v3/calendars/%<calendar_id>s/events"
    WATCH_EVENTS_URL = "https://www.googleapis.com/calendar/v3/calendars/%<calendar_id>s/events/watch"
    WATCH_CHANNEL_URL = "https://www.googleapis.com/calendar/v3/channels/stop"

    def upcoming_events(days_ahead: env_integer("DAYS_AHEAD", 180))
      events_feed(days_ahead: days_ahead).fetch(:items)
    end

    def changed_events(sync_token:)
      events_feed(sync_token: sync_token)
    end

    def events_feed(days_ahead: env_integer("DAYS_AHEAD", 180), sync_token: nil)
      url = URI(format(EVENTS_URL, calendar_id: URI.encode_www_form_component(required_env("GOOGLE_CALENDAR_ID"))))
      query = if sync_token
                {
                  maxResults: 250,
                  showDeleted: true,
                  syncToken: sync_token
                }
              else
                {
                  singleEvents: true,
                  orderBy: "startTime",
                  maxResults: 250,
                  timeMin: today_start.utc.iso8601,
                  timeMax: (Time.now.utc + days_ahead * 24 * 60 * 60).iso8601
                }
              end

      items = []
      next_page_token = nil
      next_sync_token = nil

      loop do
        current_query = query.dup
        current_query[:pageToken] = next_page_token if next_page_token
        url.query = URI.encode_www_form(current_query)

        response = HttpJson.get(url, headers: { "Authorization" => "Bearer #{access_token}" })
        items.concat(response.fetch("items", []))
        next_page_token = response["nextPageToken"]
        next_sync_token = response["nextSyncToken"] if response["nextSyncToken"]

        break unless next_page_token
      end

      {
        items: items,
        next_sync_token: next_sync_token
      }
    rescue HttpJson::Error => error
      raise SyncTokenExpired, "Google Calendar sync token expirou" if sync_token && error.code == 410

      raise
    end

    def watch_events(callback_url:, channel_id:, channel_token: nil, ttl_seconds: nil)
      url = format(WATCH_EVENTS_URL, calendar_id: URI.encode_www_form_component(required_env("GOOGLE_CALENDAR_ID")))
      body = {
        id: channel_id,
        type: "web_hook",
        address: callback_url
      }
      body[:token] = channel_token if channel_token && !channel_token.empty?
      body[:params] = { ttl: ttl_seconds.to_i.to_s } if ttl_seconds.to_i.positive?

      HttpJson.post_json(url, body: body, headers: { "Authorization" => "Bearer #{access_token}" })
    end

    def stop_watch(channel_id:, resource_id:)
      HttpJson.post_json(
        WATCH_CHANNEL_URL,
        body: {
          id: channel_id,
          resourceId: resource_id
        },
        headers: { "Authorization" => "Bearer #{access_token}" }
      )
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
      Settings.required(name)
    end

    def env_integer(name, fallback)
      Settings.integer(name, fallback)
    end

    def today_start
      Time.local(Time.now.year, Time.now.month, Time.now.day)
    end
  end
end
