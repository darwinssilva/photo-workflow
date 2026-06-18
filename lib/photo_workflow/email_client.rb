require "securerandom"
require "net/smtp"
require "time"

module PhotoWorkflow
  class EmailClient
    DEFAULT_PORT = 587
    DEFAULT_AUTH = :plain
    EMAIL_PATTERN = /[A-Z0-9._%+\-]+@[A-Z0-9.\-]+\.[A-Z]{2,}/i.freeze

    def enabled?
      env_value("EMAIL_ENABLED", "false").casecmp("true").zero?
    end

    def notify_event_created(event:, card:)
      unless enabled?
        puts "Email notification disabled for #{event.fetch("summary", event.fetch("id"))}"
        return false
      end

      recipient = recipient_for(event)
      unless recipient
        warn "Email notification skipped for #{event.fetch("summary", event.fetch("id"))}: missing client email"
        return false
      end

      deliver(
        to: recipient,
        subject: subject_for(event),
        body: body_for(event, card),
        calendar: calendar_attachment_for(event)
      )
      puts "Email notification sent to #{recipient} for #{event.fetch("summary", event.fetch("id"))}"
      true
    end

    private

    def recipient_for(event)
      email_from_description(event["description"]) || email_from_attendees(event["attendees"])
    end

    def email_from_description(description)
      return nil unless description

      description.to_s.match(EMAIL_PATTERN)&.[](0)
    end

    def email_from_attendees(attendees)
      return nil if attendees.nil? || attendees.empty?

      attendees.map { |attendee| attendee["email"] }.compact.find { |email| email.match?(EMAIL_PATTERN) }
    end

    def deliver(to:, subject:, body:, calendar:)
      boundary = "photo-workflow-#{SecureRandom.hex(12)}"
      message = [
        "From: #{from_label} <#{required_env("EMAIL_FROM")}>",
        "To: #{to}",
        "Subject: #{encode_subject(subject)}",
        "MIME-Version: 1.0",
        "Content-Type: multipart/mixed; boundary=\"#{boundary}\"",
        "",
        "--#{boundary}",
        "Content-Type: text/plain; charset=UTF-8",
        "Content-Transfer-Encoding: 8bit",
        "",
        body,
        "",
        "--#{boundary}",
        "Content-Type: text/calendar; charset=UTF-8; method=PUBLISH; name=\"ensaio.ics\"",
        "Content-Disposition: attachment; filename=\"ensaio.ics\"",
        "Content-Transfer-Encoding: 8bit",
        "",
        calendar,
        "",
        "--#{boundary}--"
      ].join("\r\n")

      smtp = Net::SMTP.new(required_env("SMTP_HOST"), env_integer("SMTP_PORT", DEFAULT_PORT))
      smtp.enable_starttls_auto if starttls?
      smtp.start(required_env("SMTP_DOMAIN"), required_env("SMTP_USERNAME"), required_env("SMTP_PASSWORD"), auth_method) do |connection|
        connection.send_message(message, required_env("EMAIL_FROM"), to)
      end
    end

    def subject_for(event)
      env_value("EMAIL_SUBJECT_PREFIX", "Confirmacao de ensaio") + " - " + event.fetch("summary", "")
    end

    def body_for(event, card)
      template = env_value("EMAIL_BODY_TEMPLATE")
      return interpolate(template, event, card) if template && !template.empty?

      [
        "Ola!",
        "",
        "Seu ensaio foi agendado com sucesso.",
        "",
        "Ensaio: #{event.fetch("summary", "")}",
        "Data: #{formatted_time(event.fetch("start", {}))}",
        optional_line("Local", event["location"]),
        optional_line("Adicionar ao calendario", event["htmlLink"]),
        "",
        "Tambem anexamos um arquivo ensaio.ics para adicionar este ensaio ao seu calendario.",
        "",
        "Se precisar ajustar alguma informacao, responda este e-mail.",
        "",
        "Atenciosamente,",
        from_name
      ].compact.join("\n")
    end

    def interpolate(template, event, card)
      replacements = {
        "summary" => event.fetch("summary", ""),
        "start" => formatted_time(event.fetch("start", {})),
        "end" => formatted_time(event.fetch("end", {})),
        "location" => event.fetch("location", ""),
        "description" => event.fetch("description", ""),
        "calendar_link" => event.fetch("htmlLink", ""),
        "trello_link" => card["shortUrl"] || card["url"] || ""
      }

      replacements.reduce(template) do |text, (key, value)|
        text.gsub("{{#{key}}}", value.to_s)
      end
    end

    def formatted_time(date_hash)
      value = date_hash["dateTime"] || date_hash["date"]
      return "" unless value

      Time.parse(value).strftime("%d/%m/%Y %H:%M")
    rescue ArgumentError
      value.to_s
    end

    def calendar_attachment_for(event)
      [
        "BEGIN:VCALENDAR",
        "VERSION:2.0",
        "PRODID:-//Photo Workflow//Calendar Confirmation//PT-BR",
        "CALSCALE:GREGORIAN",
        "METHOD:PUBLISH",
        "BEGIN:VEVENT",
        "UID:#{ics_escape(event["iCalUID"] || "#{event.fetch("id", SecureRandom.uuid)}@photo-workflow")}",
        "DTSTAMP:#{ics_datetime(Time.now.utc)}",
        ics_date_property("DTSTART", event.fetch("start", {})),
        ics_date_property("DTEND", event.fetch("end", {})),
        "SUMMARY:#{ics_escape(event.fetch("summary", ""))}",
        optional_ics_line("LOCATION", event["location"]),
        optional_ics_line("DESCRIPTION", calendar_description(event)),
        optional_ics_line("URL", event["htmlLink"]),
        "END:VEVENT",
        "END:VCALENDAR"
      ].compact.join("\r\n") + "\r\n"
    end

    def calendar_description(event)
      [
        "Ensaio agendado.",
        event["description"],
        event["htmlLink"]
      ].compact.join("\n\n")
    end

    def ics_date_property(name, date_hash)
      if date_hash["date"]
        "#{name};VALUE=DATE:#{date_hash.fetch("date").delete("-")}"
      else
        "#{name}:#{ics_datetime(Time.parse(date_hash.fetch("dateTime")).utc)}"
      end
    end

    def ics_datetime(time)
      time.strftime("%Y%m%dT%H%M%SZ")
    end

    def optional_ics_line(name, value)
      return nil if value.nil? || value.to_s.empty?

      "#{name}:#{ics_escape(value)}"
    end

    def ics_escape(value)
      value.to_s
           .gsub("\\", "\\\\\\")
           .gsub(";", "\\;")
           .gsub(",", "\\,")
           .gsub(/\r\n|\r|\n/, "\\n")
    end

    def optional_line(label, value)
      return nil if value.nil? || value.to_s.empty?

      "#{label}: #{value}"
    end

    def encode_subject(subject)
      "=?UTF-8?B?#{[subject].pack("m0")}?="
    end

    def from_label
      from_name.gsub(/[<>\r\n]/, "")
    end

    def from_name
      env_value("EMAIL_FROM_NAME", "Photo Workflow")
    end

    def starttls?
      env_value("SMTP_STARTTLS", "true").casecmp("true").zero?
    end

    def auth_method
      env_value("SMTP_AUTH", DEFAULT_AUTH.to_s).to_sym
    end

    def env_integer(name, fallback)
      env_value(name, fallback).to_i
    end

    def required_env(name)
      value = env_value(name)
      raise "Missing ENV #{name}" if value.nil?

      value
    end

    def env_value(name, fallback = nil)
      value = ENV[name]
      return fallback if value.nil? || value.empty?

      value
    end
  end
end
