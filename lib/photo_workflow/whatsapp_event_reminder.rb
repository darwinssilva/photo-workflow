require "date"
require "time"

require_relative "google_calendar_client"
require_relative "settings"
require_relative "state_store"
require_relative "whatsapp_client"

module PhotoWorkflow
  class WhatsAppEventReminder
    def initialize(calendar_client: GoogleCalendarClient.new, whatsapp_client: WhatsAppClient.new, state_store: StateStore.new(path: Settings.value("WHATSAPP_REMINDER_STATE_PATH", "data/whatsapp_event_reminders.json")), today: Date.today)
      @calendar_client = calendar_client
      @whatsapp_client = whatsapp_client
      @state_store = state_store
      @today = today
    end

    def call(events: nil)
      unless whatsapp_client.enabled?
        puts "WhatsApp reminder disabled."
        return { sent_count: 0, skipped_count: 0 }
      end

      state_store.with_lock do
        state = state_store.all
        events ||= calendar_client.upcoming_events(days_ahead: reminder_days_ahead)
        sent_count = 0
        skipped_count = 0

        reminder_events(events).each do |event|
          next if reminder_already_handled?(event, state)

          case send_reminder(event)
          when :sent
            mark_reminder(state, event, "sent")
            sent_count += 1
          when :missing_phone
            mark_reminder(state, event, "skipped_missing_phone")
            skipped_count += 1
          when :disabled
            skipped_count += 1
          end
        end

        state_store.save(state)
        puts "WhatsApp reminder finished. #{sent_count} sent, #{skipped_count} skipped."

        { sent_count: sent_count, skipped_count: skipped_count }
      end
    end

    private

    attr_reader :calendar_client, :whatsapp_client, :state_store, :today

    def reminder_events(events)
      events.select do |event|
        syncable_event?(event) && event_start(event).to_date == reminder_date
      end
    end

    def syncable_event?(event)
      summary = event.fetch("summary", "")
      normalized_summary = summary.to_s.strip.gsub(/[[:punct:]\s]+\z/, "")

      event["status"] != "cancelled" &&
        summary.match?(event_summary_pattern) &&
        !summary.match?(excluded_event_summary_pattern) &&
        !normalized_summary.casecmp("Agenda fechada").zero?
    end

    def send_reminder(event)
      whatsapp_client.notify_event_reminder(event: event)
    rescue StandardError => error
      warn "WhatsApp reminder failed for #{event.fetch("summary", event.fetch("id", "unknown"))}: #{error.message}"
      nil
    end

    def mark_reminder(state, event, status)
      state[state_key(event)] = {
        "google_event_id" => event.fetch("id"),
        "summary" => event.fetch("summary", ""),
        "starts_at" => event_start(event).iso8601,
        "reminder_date" => today.iso8601,
        "target_event_date" => reminder_date.iso8601,
        "status" => status,
        "recorded_at" => Time.now.utc.iso8601
      }
    end

    def reminder_already_handled?(event, state)
      state.key?(state_key(event))
    end

    def state_key(event)
      ["lembre_ensaio", event.fetch("id"), reminder_date.iso8601].join(":")
    end

    def event_start(event)
      start = event.fetch("start")
      value = start["dateTime"] || start["date"]
      Time.parse(value)
    end

    def reminder_date
      today + reminder_days_before_event
    end

    def reminder_days_before_event
      Settings.integer("WHATSAPP_REMINDER_DAYS_BEFORE_EVENT", 1)
    end

    def reminder_days_ahead
      [reminder_days_before_event + 1, 1].max
    end

    def event_summary_pattern
      Regexp.new(Settings.value("EVENT_SUMMARY_PATTERN", "."), Regexp::IGNORECASE)
    end

    def excluded_event_summary_pattern
      Regexp.new(Settings.value("EXCLUDED_EVENT_SUMMARY_PATTERN", "\\A\\z"), Regexp::IGNORECASE)
    end
  end
end
