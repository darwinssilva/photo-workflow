require "digest"
require "json"
require "time"

require_relative "email_client"
require_relative "google_calendar_client"
require_relative "state_store"
require_relative "trello_client"
require_relative "whatsapp_client"

module PhotoWorkflow
  class CalendarToTrelloSync
    def initialize(calendar_client: GoogleCalendarClient.new, trello_client: TrelloClient.new, state_store: StateStore.new, whatsapp_client: WhatsAppClient.new, email_client: EmailClient.new)
      @calendar_client = calendar_client
      @trello_client = trello_client
      @state_store = state_store
      @whatsapp_client = whatsapp_client
      @email_client = email_client
    end

    def call
      state = state_store.all
      events = calendar_client.upcoming_events
      synced_count = 0
      archived_count = archive_removed_events(state, events)

      events.each do |event|
        next unless syncable_event?(event)

        event_id = event.fetch("id")
        payload = card_payload(event)
        fingerprint = fingerprint_for(payload)
        current_state = state[event_id]

        if should_create_card?(current_state)
          card = trello_client.create_card(**payload)
          state[event_id] = state_payload(event, card.fetch("id"), fingerprint, trello_card_url(card))
          handle_email_notification_result(state[event_id], notify_event_created(event, card))
          synced_count += 1
          puts "Created Trello card for #{event.fetch("summary")}"
        elsif current_state["fingerprint"] != fingerprint
          trello_client.update_card(current_state.fetch("trello_card_id"), **payload)
          state[event_id] = state_payload(event, current_state.fetch("trello_card_id"), fingerprint, current_state["trello_card_url"])
          preserve_email_notification(state[event_id], current_state)
          handle_email_notification_result(state[event_id], notify_email_created(event, trello_card_reference(state[event_id]))) if email_notification_pending?(state[event_id])
          synced_count += 1
          puts "Updated Trello card for #{event.fetch("summary")}"
        elsif email_notification_pending?(current_state)
          card = trello_card_reference(current_state)
          handle_email_notification_result(current_state, notify_email_created(event, card))
        end
      end

      state_store.save(state)
      puts "Sync finished. #{synced_count} card(s) created or updated."
      puts "Archive finished. #{archived_count} card(s) archived."
    end

    private

    attr_reader :calendar_client, :trello_client, :state_store, :whatsapp_client, :email_client

    def syncable_event?(event)
      summary = event.fetch("summary", "")

      event["status"] != "cancelled" &&
        summary.match?(event_summary_pattern) &&
        !summary.match?(excluded_event_summary_pattern)
    end

    def event_summary_pattern
      Regexp.new(ENV.fetch("EVENT_SUMMARY_PATTERN", "."), Regexp::IGNORECASE)
    end

    def excluded_event_summary_pattern
      Regexp.new(ENV.fetch("EXCLUDED_EVENT_SUMMARY_PATTERN", "\\A\\z"), Regexp::IGNORECASE)
    end

    def should_create_card?(record)
      return true if record.nil? || record["archived_at"]

      if trello_card_inactive?(record)
        puts "Trello card missing or archived for #{record.fetch("summary", record.fetch("google_event_id", "unknown"))}; creating a new card."
        return true
      end

      false
    end

    def trello_card_inactive?(record)
      !trello_client.active_card?(record.fetch("trello_card_id"))
    rescue KeyError
      true
    end

    def archive_removed_events(state, events)
      active_event_ids = events.reject { |event| event["status"] == "cancelled" }.map { |event| event.fetch("id") }
      archived_count = 0

      state.each do |event_id, record|
        next if record["archived_at"]
        next if active_event_ids.include?(event_id)
        next unless tracked_event_still_relevant?(record)

        archive_trello_card(record)
        record["archived_at"] = Time.now.utc.iso8601
        archived_count += 1
        puts "Archived Trello card for #{record.fetch("summary", event_id)}"
      end

      archived_count
    end

    def archive_trello_card(record)
      trello_client.archive_card(record.fetch("trello_card_id"))
    rescue HttpJson::Error => error
      raise unless error.code == 404

      puts "Trello card already missing for #{record.fetch("summary", record.fetch("google_event_id", "unknown"))}; marking as archived."
    end

    def notify_event_created(event, card)
      notify_with("WhatsApp", event) { whatsapp_client.notify_event_created(event: event, card: card) }
      notify_email_created(event, card)
    end

    def notify_email_created(event, card)
      notify_with("Email", event) { email_client.notify_event_created(event: event, card: card) }
    end

    def notify_with(channel, event)
      yield
    rescue StandardError => error
      warn "#{channel} notification failed for #{event.fetch("summary", event.fetch("id"))}: #{error.message}"
      false
    end

    def email_notification_pending?(record)
      email_client.enabled? &&
        !record["email_notified_at"] &&
        record["email_skipped_fingerprint"] != record["fingerprint"]
    end

    def mark_email_notification(record, timestamp = Time.now.utc.iso8601)
      record["email_notified_at"] = timestamp
      record.delete("email_skipped_at")
      record.delete("email_skip_reason")
      record.delete("email_skipped_fingerprint")
    end

    def mark_email_skip(record, reason, timestamp = Time.now.utc.iso8601)
      record["email_skipped_at"] = timestamp
      record["email_skip_reason"] = reason
      record["email_skipped_fingerprint"] = record["fingerprint"]
    end

    def preserve_email_notification(record, previous_record)
      return unless previous_record["email_notified_at"]

      mark_email_notification(record, previous_record["email_notified_at"])
    end

    def handle_email_notification_result(record, result)
      case result
      when :sent
        mark_email_notification(record)
      when :missing_client_email
        mark_email_skip(record, "missing_client_email")
      end
    end

    def trello_card_reference(record)
      {
        "id" => record.fetch("trello_card_id"),
        "shortUrl" => record["trello_card_url"]
      }
    end

    def trello_card_url(card)
      card["shortUrl"] || card["url"]
    end

    def tracked_event_still_relevant?(record)
      Time.parse(record.fetch("starts_at")) >= today_start
    rescue KeyError, ArgumentError
      true
    end

    def today_start
      Time.local(Time.now.year, Time.now.month, Time.now.day)
    end

    def card_payload(event)
      {
        name: event.fetch("summary"),
        desc: card_description(event),
        due: delivery_date(event)
      }
    end

    def card_description(event)
      [
        "Ensaio criado automaticamente pela agenda.",
        "",
        "Titulo: #{event["summary"]}",
        "Status: #{event["status"]}",
        "Inicio: #{event_start(event)}",
        "Fim: #{event_end(event)}",
        "Local: #{event["location"]}",
        "Link da agenda: #{event["htmlLink"]}",
        "Criador: #{person_label(event["creator"])}",
        "Organizador: #{person_label(event["organizer"])}",
        "Participantes: #{attendees_label(event["attendees"])}",
        "",
        "Descricao da agenda:",
        event["description"],
        "",
        "Dados completos da agenda:",
        "```json",
        JSON.pretty_generate(event),
        "```"
      ].compact.join("\n")
    end

    def delivery_date(event)
      event_start(event) + delivery_days_after_event * 24 * 60 * 60
    end

    def event_start(event)
      start = event.fetch("start")
      value = start["dateTime"] || start["date"]
      Time.parse(value)
    end

    def event_end(event)
      ending = event.fetch("end")
      value = ending["dateTime"] || ending["date"]
      Time.parse(value)
    rescue KeyError, ArgumentError
      nil
    end

    def person_label(person)
      return nil unless person

      [person["displayName"], person["email"]].compact.join(" - ")
    end

    def attendees_label(attendees)
      return nil if attendees.nil? || attendees.empty?

      attendees.map { |attendee| person_label(attendee) || attendee["email"] }.compact.join(", ")
    end

    def delivery_days_after_event
      ENV.fetch("DELIVERY_DAYS_AFTER_EVENT", 0).to_i
    end

    def fingerprint_for(payload)
      Digest::SHA256.hexdigest(Marshal.dump(payload))
    end

    def state_payload(event, trello_card_id, fingerprint, trello_card_url = nil)
      {
        "google_event_id" => event.fetch("id"),
        "trello_card_id" => trello_card_id,
        "trello_card_url" => trello_card_url,
        "summary" => event.fetch("summary"),
        "starts_at" => event_start(event).iso8601,
        "fingerprint" => fingerprint,
        "synced_at" => Time.now.utc.iso8601
      }
    end
  end
end
