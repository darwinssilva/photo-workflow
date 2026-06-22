require_relative "calendar_to_trello_sync"
require_relative "google_calendar_client"
require_relative "settings"
require_relative "state_store"

module PhotoWorkflow
  class GoogleCalendarWebhookHandler
    def initialize(calendar_client: GoogleCalendarClient.new, sync_service: nil, webhook_state_store: StateStore.new(path: Settings.value("WEBHOOK_STATE_PATH", "data/google_calendar_webhook_state.json")))
      @calendar_client = calendar_client
      @sync_service = sync_service || CalendarToTrelloSync.new(calendar_client: calendar_client)
      @webhook_state_store = webhook_state_store
    end

    def call(headers:)
      return response(401, "invalid channel token") unless valid_channel_token?(headers)

      resource_state = header_value(headers, "X-Goog-Resource-State")
      return response(400, "missing resource state") if resource_state.nil? || resource_state.empty?

      state = webhook_state_store.all

      reconcile_channel_metadata!(state, headers)
      result = process_notification(resource_state: resource_state, state: state)

      save_channel_metadata(state, headers)
      webhook_state_store.save(state)

      response(200, "ok: synced=#{result[:synced_count]} archived=#{result[:archived_count]}")
    rescue StandardError => error
      warn "Webhook processing failed: #{error.class} - #{error.message}"
      response(500, "error")
    end

    private

    attr_reader :calendar_client, :sync_service, :webhook_state_store

    def process_notification(resource_state:, state:)
      return { synced_count: 0, archived_count: 0 } if resource_state == "sync"

      sync_token = state["sync_token"]
      return full_resync(state) if sync_token.nil? || sync_token.empty?

      incremental_sync(state, sync_token)
    rescue GoogleCalendarClient::SyncTokenExpired
      warn "Google Calendar sync token expirou; executando resync completo."
      full_resync(state)
    end

    def full_resync(state)
      feed = calendar_client.events_feed
      result = sync_service.call(events: feed.fetch(:items), archive_missing: true)
      state["sync_token"] = feed[:next_sync_token] if feed[:next_sync_token]
      result
    end

    def incremental_sync(state, sync_token)
      feed = calendar_client.changed_events(sync_token: sync_token)
      result = sync_service.call(events: feed.fetch(:items), archive_missing: false)
      state["sync_token"] = feed[:next_sync_token] if feed[:next_sync_token]
      result
    end

    def reconcile_channel_metadata!(state, headers)
      expected_channel_id = state["channel_id"]
      expected_resource_id = state["resource_id"]
      incoming_channel_id = header_value(headers, "X-Goog-Channel-ID")
      incoming_resource_id = header_value(headers, "X-Goog-Resource-ID")

      if expected_channel_id && incoming_channel_id && expected_channel_id != incoming_channel_id
        warn "Webhook channel_id mudou de #{expected_channel_id} para #{incoming_channel_id}; atualizando estado local."
      end

      if expected_resource_id && incoming_resource_id && expected_resource_id != incoming_resource_id
        warn "Webhook resource_id mudou de #{expected_resource_id} para #{incoming_resource_id}; forçando resync completo."
        state.delete("sync_token")
      end
    end

    def save_channel_metadata(state, headers)
      state["channel_id"] = header_value(headers, "X-Goog-Channel-ID") if header_value(headers, "X-Goog-Channel-ID")
      state["resource_id"] = header_value(headers, "X-Goog-Resource-ID") if header_value(headers, "X-Goog-Resource-ID")
      state["resource_uri"] = header_value(headers, "X-Goog-Resource-URI") if header_value(headers, "X-Goog-Resource-URI")
      state["channel_expiration"] = header_value(headers, "X-Goog-Channel-Expiration") if header_value(headers, "X-Goog-Channel-Expiration")
      state["last_notification_at"] = Time.now.utc.iso8601
      state["last_message_number"] = header_value(headers, "X-Goog-Message-Number")
      state["last_resource_state"] = header_value(headers, "X-Goog-Resource-State")
    end

    def valid_channel_token?(headers)
      expected = Settings.value("WEBHOOK_SHARED_TOKEN", "").to_s
      return true if expected.empty?

      token = header_value(headers, "X-Goog-Channel-Token").to_s
      !token.empty? && token == expected
    end

    def header_value(headers, name)
      return nil if headers.nil?

      headers[name] || headers[name.downcase] || headers[name.gsub("-", "_")]
    end

    def response(status, body)
      {
        status: status,
        body: body
      }
    end
  end
end
