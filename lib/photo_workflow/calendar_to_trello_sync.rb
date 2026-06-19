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

    def call(events: nil, archive_missing: true)
      state = state_store.all
      events ||= calendar_client.upcoming_events
      synced_count = 0
      archived_count = archive_missing ? archive_removed_events(state, events) : 0

      events.each do |event|
        archived_count += 1 if archive_if_no_longer_syncable(state, event)
        next unless syncable_event?(event)

        event_id = event.fetch("id")
        payload = card_payload(event)
        fingerprint = fingerprint_for(payload)
        current_state = state[event_id]

        if should_create_card?(current_state)
          existing_card = find_existing_card(payload)
          if existing_card
            trello_client.update_card(existing_card.fetch("id"), **payload)
            state[event_id] = state_payload(event, existing_card.fetch("id"), fingerprint, trello_card_url(existing_card))
            preserve_email_notification(state[event_id], current_state) if current_state
            handle_email_notification_result(state[event_id], notify_email_created(event, trello_card_reference(state[event_id]))) if email_notification_pending?(state[event_id])
            puts "Reused existing Trello card for #{event.fetch("summary")}"
          else
            card = trello_client.create_card(**payload)
            state[event_id] = state_payload(event, card.fetch("id"), fingerprint, trello_card_url(card))
            handle_email_notification_result(state[event_id], notify_event_created(event, card))
            puts "Created Trello card for #{event.fetch("summary")}"
          end
          synced_count += 1
        elsif current_state["fingerprint"] != fingerprint
          trello_client.update_card(current_state.fetch("trello_card_id"), **payload)
          state[event_id] = state_payload(event, current_state.fetch("trello_card_id"), fingerprint, current_state["trello_card_url"])
          preserve_email_notification(state[event_id], current_state)

          if event_update_notifications_enabled? && notification_relevant_update?(current_state, event)
            handle_email_notification_result(state[event_id], notify_event_updated(event, trello_card_reference(state[event_id])))
          elsif email_notification_pending?(state[event_id])
            handle_email_notification_result(state[event_id], notify_email_created(event, trello_card_reference(state[event_id])))
          end

          synced_count += 1
          puts "Updated Trello card for #{event.fetch("summary")}"
        elsif email_notification_pending?(current_state)
          card = trello_card_reference(current_state)
          handle_email_notification_result(current_state, notify_email_created(event, card))
        end
      end

      sort_trello_lists
      state_store.save(state)
      puts "Sync finished. #{synced_count} card(s) created or updated."
      puts "Archive finished. #{archived_count} card(s) archived."

      {
        synced_count: synced_count,
        archived_count: archived_count
      }
    end

    private

    attr_reader :calendar_client, :trello_client, :state_store, :whatsapp_client, :email_client

    def syncable_event?(event)
      summary = event.fetch("summary", "")

      event["status"] != "cancelled" &&
        summary.match?(event_summary_pattern) &&
        !summary.match?(excluded_event_summary_pattern)
    end

    def archive_if_no_longer_syncable(state, event)
      return false if syncable_event?(event)

      event_id = event["id"]
      return false if event_id.nil? || event_id.empty?

      record = state[event_id]
      return false unless record && !record["archived_at"]

      archive_trello_card(record)
      record["archived_at"] = Time.now.utc.iso8601
      puts "Archived Trello card for #{record.fetch("summary", event_id)}"
      true
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
        puts "Trello card missing or archived for #{record.fetch("summary", record.fetch("google_event_id", "unknown"))}; searching for an active matching card."
        return true
      end

      false
    end

    def find_existing_card(payload)
      trello_client.find_active_card_by_name(payload.fetch(:name))
    rescue HttpJson::Error => error
      warn "Could not search existing Trello card for #{payload.fetch(:name)}: #{error.message}"
      nil
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

    def sort_trello_lists
      sort_trello_list(required_env("TRELLO_LIST_ID"), direction: :asc)
      reminder_list_ids.each { |list_id| sort_trello_list(list_id, direction: :asc) }
    end

    def sort_trello_list(list_id, direction:)
      cards = trello_client.list_cards(list_id).reject { |card| card["closed"] }
      sorted_cards = cards.sort_by { |card| [card_due_sort_value(card), card["name"].to_s] }
      sorted_cards.reverse! if direction == :desc

      sorted_cards.each_with_index do |card, index|
        target_pos = (index + 1) * 1024
        next if card["pos"].to_f == target_pos

        trello_client.update_card_position(card.fetch("id"), pos: target_pos)
      end

      puts "Sorted #{sorted_cards.size} Trello card(s) in list #{list_id} by due date."
    rescue HttpJson::Error => error
      warn "Could not sort Trello cards in list #{list_id}: #{error.message}"
    end

    def card_due_sort_value(card)
      value = card["due"]
      return Time.at(2**31 - 1) if value.nil? || value.empty?

      Time.parse(value)
    rescue ArgumentError
      Time.at(2**31 - 1)
    end

    def reminder_list_ids
      [
        env_value("TRELLO_GALLERY_LIST_ID", "69026faa813ce18fe16387e7"),
        env_value("TRELLO_EDITING_LIST_ID", "69026fe3e95b323354f27f6d"),
        env_value("TRELLO_PAYMENT_LIST_ID", "6a330b1331176309a014e4e7"),
        env_value("TRELLO_EXTRA_PAYMENT_LIST_ID", "6a33287ddf1a985770fec18c")
      ].compact.reject(&:empty?).uniq
    end

    def notify_event_created(event, card)
      notify_with("WhatsApp", event) { whatsapp_client.notify_event_created(event: event, card: card) }
      notify_email_created(event, card)
    end

    def notify_event_updated(event, card)
      notify_with("WhatsApp", event) { whatsapp_client.notify_event_created(event: event, card: card) }
      notify_email_updated(event, card)
    end

    def notify_email_created(event, card)
      notify_with("Email", event) { email_client.notify_event_created(event: event, card: card) }
    end

    def notify_email_updated(event, card)
      notify_with("Email", event) { email_client.notify_event_created(event: event, card: card) }
    end

    def event_update_notifications_enabled?
      env_value("NOTIFY_ON_EVENT_UPDATE", "true").casecmp("true").zero?
    end

    def notification_relevant_update?(previous_record, event)
      previous_summary = previous_record["summary"].to_s
      current_summary = event.fetch("summary", "").to_s
      return true if previous_summary != current_summary

      previous_starts_at = previous_record["starts_at"].to_s
      current_starts_at = event_start(event).iso8601
      return true if previous_starts_at != current_starts_at

      previous_description = previous_record["description"].to_s
      current_description = event.fetch("description", "").to_s
      previous_description != current_description
    rescue StandardError
      true
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

    def required_env(name)
      ENV.fetch(name) { raise "Missing ENV #{name}" }
    end

    def env_value(name, fallback = nil)
      value = ENV[name]
      return fallback if value.nil? || value.empty?

      value
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
        "description" => event.fetch("description", ""),
        "fingerprint" => fingerprint,
        "synced_at" => Time.now.utc.iso8601
      }
    end
  end
end
