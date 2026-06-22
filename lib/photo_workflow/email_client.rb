require "securerandom"
require "base64"
require "net/smtp"
require "time"
require "timeout"

require_relative "http_json"
require_relative "settings"

module PhotoWorkflow
  class EmailClient
    DEFAULT_PORT = 587
    DEFAULT_AUTH = :plain
    DEFAULT_OPEN_TIMEOUT = 10
    DEFAULT_READ_TIMEOUT = 30
    DEFAULT_RETRIES = 1
    EMAIL_PATTERN = /[A-Z0-9._%+\-]+@[A-Z0-9.\-]+\.[A-Z]{2,}/i.freeze

    def enabled?
      Settings.boolean("EMAIL_ENABLED", false)
    end

    def notify_event_created(event:, card:)
      notify_event(event: event, card: card, kind: :created)
    end

    def notify_event_updated(event:, card:)
      notify_event(event: event, card: card, kind: :updated)
    end

    def notify_event(event:, card:, kind:)
      unless enabled?
        puts "Email notification disabled for #{event.fetch("summary", event.fetch("id"))}"
        return :disabled
      end

      recipient = recipient_for(event)
      unless recipient
        warn "Email notification skipped for #{event.fetch("summary", event.fetch("id"))}: missing client email"
        return :missing_client_email
      end

      deliver(
        to: recipient,
        subject: subject_for(event, kind: kind),
        body: body_for(event, card, kind: kind),
        calendar: calendar_attachment_for(event, recipient)
      )
      puts "Email notification (#{kind}) sent to #{recipient} for #{event.fetch("summary", event.fetch("id"))}"
      :sent
    end

    def deliver_text(to:, subject:, body:)
      recipients = Array(to).map(&:to_s).map(&:strip).reject(&:empty?)
      raise "Missing email recipient" if recipients.empty?

      deliver(
        to: recipients,
        subject: subject,
        body: body,
        calendar: nil
      )
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
      recipients = Array(to).map(&:to_s).map(&:strip).reject(&:empty?)
      if resend_enabled?
        deliver_with_resend(to: recipients, subject: subject, body: body, calendar: calendar)
        return
      end

      boundary = "photo-workflow-#{SecureRandom.hex(12)}"
      parts = [
        "From: #{from_label} <#{required_env("EMAIL_FROM")}>",
        "To: #{recipients.join(", ")}",
        "Subject: #{encode_subject(subject)}",
        "MIME-Version: 1.0",
        "Content-Type: multipart/mixed; boundary=\"#{boundary}\"",
        "",
        "--#{boundary}",
        "Content-Type: text/plain; charset=UTF-8",
        "Content-Transfer-Encoding: 8bit",
        "",
        body,
        ""
      ]

      if calendar
        parts.concat([
          "--#{boundary}",
          "Content-Type: text/calendar; charset=UTF-8; method=REQUEST; name=\"ensaio.ics\"",
          "Content-Class: urn:content-classes:calendarmessage",
          "Content-Disposition: attachment; filename=\"ensaio.ics\"",
          "Content-Transfer-Encoding: 8bit",
          "",
          calendar,
          ""
        ])
      end

      parts << "--#{boundary}--"
      message = parts.join("\r\n")

      with_smtp_retries do
        smtp = Net::SMTP.new(required_env("SMTP_HOST"), env_integer("SMTP_PORT", DEFAULT_PORT))
        smtp.open_timeout = env_integer("SMTP_OPEN_TIMEOUT", DEFAULT_OPEN_TIMEOUT)
        smtp.read_timeout = env_integer("SMTP_READ_TIMEOUT", DEFAULT_READ_TIMEOUT)

        if smtp_ssl?
          smtp.enable_tls
        elsif starttls?
          smtp.enable_starttls_auto
        end

        smtp.start(required_env("SMTP_DOMAIN"), required_env("SMTP_USERNAME"), required_env("SMTP_PASSWORD"), auth_method) do |connection|
          connection.send_message(message, required_env("EMAIL_FROM"), recipients)
        end
      end
    end

    def deliver_with_resend(to:, subject:, body:, calendar:)
      payload = {
        from: resend_from,
        to: to,
        subject: subject,
        text: body
      }

      if calendar
        payload[:attachments] = [
          {
            filename: "ensaio.ics",
            content: Base64.strict_encode64(calendar),
            content_type: "text/calendar"
          }
        ]
      end

      HttpJson.post_json(
        "https://api.resend.com/emails",
        headers: { "Authorization" => "Bearer #{required_env("RESEND_API_KEY")}" },
        body: payload
      )
    end

    def with_smtp_retries
      attempts = env_integer("SMTP_RETRIES", DEFAULT_RETRIES)
      current_attempt = 0

      begin
        current_attempt += 1
        yield
      rescue Net::OpenTimeout, Net::ReadTimeout, Timeout::Error, EOFError, Errno::ECONNRESET, Errno::ETIMEDOUT, SocketError => error
        retry if current_attempt <= attempts

        raise "SMTP connection failed after #{current_attempt} attempt(s): #{error.class} - #{error.message}"
      end
    end

    def subject_for(event, kind: :created)
      prefix = case kind
               when :updated
                 env_value("EMAIL_SUBJECT_PREFIX_UPDATED", env_value("EMAIL_SUBJECT_PREFIX", "Atualizacao de ensaio"))
               else
                 env_value("EMAIL_SUBJECT_PREFIX", "Confirmacao de ensaio")
               end

      prefix + " - " + event.fetch("summary", "")
    end

    def body_for(event, card, kind: :created)
      template = case kind
                 when :updated
                   env_value("EMAIL_BODY_TEMPLATE_UPDATED") || env_value("EMAIL_BODY_TEMPLATE")
                 else
                   env_value("EMAIL_BODY_TEMPLATE")
                 end
      return interpolate(template, event, card) if template && !template.empty?

      form_fields = form_fields_for(event)

      intro = kind == :updated ? "Seu ensaio foi atualizado com sucesso." : "Seu ensaio foi agendado com sucesso."

      [
        "Ola!",
        "",
        intro,
        "",
        "Ensaio: #{event.fetch("summary", "")}",
        optional_line("Nome", form_fields["nome"]),
        optional_line("Modelo", form_fields["modelo"]),
        optional_line("Tipo", form_fields["tipo"]),
        "Data: #{formatted_time(event.fetch("start", {}))}",
        optional_line("Local", event["location"]),
        optional_line("Referencias", form_fields["referencias"]),
        "",
        "Para adicionar ao seu calendario, use o convite anexado neste e-mail.",
        "",
        "Se precisar ajustar alguma informacao, responda este e-mail.",
        "",
        "Atenciosamente,",
        from_name
      ].compact.join("\n")
    end

    def interpolate(template, event, card)
      form_fields = form_fields_for(event)
      replacements = {
        "client_name" => form_fields["nome"],
        "model_name" => form_fields["modelo"],
        "shoot_type" => form_fields["tipo"],
        "references" => form_fields["referencias"],
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

    def form_fields_for(event)
      description_fields(event["description"]).merge(
        "nome" => description_field(event["description"], "Nome"),
        "modelo" => description_field(event["description"], "Modelo"),
        "tipo" => description_field(event["description"], "Tipo"),
        "referencias" => description_field(event["description"], "Referencias")
      ) { |_key, old_value, new_value| old_value.to_s.empty? ? new_value : old_value }
    end

    def description_fields(description)
      return {} unless description

      description.to_s.each_line.each_with_object({}) do |line, fields|
        key, value = line.split(":", 2)
        next unless value

        normalized_key = normalize_description_key(key)
        fields[normalized_key] = value.strip unless normalized_key.empty?
      end
    end

    def description_field(description, field_name)
      description_fields(description).fetch(normalize_description_key(field_name), "")
    end

    def normalize_description_key(key)
      key.to_s
         .downcase
         .tr("áàâãäéèêëíìîïóòôõöúùûüç", "aaaaaeeeeiiiiooooouuuuc")
         .gsub(/[^a-z0-9]+/, "_")
         .gsub(/\A_+|_+\z/, "")
    end

    def formatted_time(date_hash)
      value = date_hash["dateTime"] || date_hash["date"]
      return "" unless value

      Time.parse(value).strftime("%d/%m/%Y %H:%M")
    rescue ArgumentError
      value.to_s
    end

    def calendar_attachment_for(event, attendee_email)
      timezone = calendar_timezone(event)

      [
        "BEGIN:VCALENDAR",
        "VERSION:2.0",
        "PRODID:-//Photo Workflow//Calendar Confirmation//PT-BR",
        "CALSCALE:GREGORIAN",
        "METHOD:REQUEST",
        "X-WR-TIMEZONE:#{ics_escape(timezone)}",
        "BEGIN:VEVENT",
        "UID:#{ics_escape(event["iCalUID"] || "#{event.fetch("id", SecureRandom.uuid)}@photo-workflow")}",
        "DTSTAMP:#{ics_datetime(Time.now.utc)}",
        ics_date_property("DTSTART", event.fetch("start", {}), timezone),
        ics_date_property("DTEND", event.fetch("end", {}), timezone),
        "SUMMARY:#{ics_escape(event.fetch("summary", ""))}",
        optional_ics_line("LOCATION", event["location"]),
        optional_ics_line("DESCRIPTION", calendar_description(event)),
        optional_ics_line("URL", event["htmlLink"]),
        organizer_line(event),
        "ATTENDEE;CN=#{ics_escape(attendee_email)};ROLE=REQ-PARTICIPANT;PARTSTAT=NEEDS-ACTION;RSVP=TRUE:mailto:#{attendee_email}",
        "STATUS:CONFIRMED",
        "SEQUENCE:#{event.fetch("sequence", 0)}",
        "TRANSP:OPAQUE",
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

    def ics_date_property(name, date_hash, timezone)
      if date_hash["date"]
        "#{name};VALUE=DATE:#{date_hash.fetch("date").delete("-")}"
      else
        "#{name};TZID=#{timezone}:#{ics_local_datetime(Time.parse(date_hash.fetch("dateTime")))}"
      end
    end

    def ics_datetime(time)
      time.strftime("%Y%m%dT%H%M%SZ")
    end

    def ics_local_datetime(time)
      time.strftime("%Y%m%dT%H%M%S")
    end

    def calendar_timezone(event)
      event.dig("start", "timeZone") || event.dig("end", "timeZone") || env_value("CALENDAR_TIMEZONE", "America/Sao_Paulo")
    end

    def organizer_line(event)
      email = event.dig("organizer", "email") || required_env("EMAIL_FROM")
      name = event.dig("organizer", "displayName") || from_name

      "ORGANIZER;CN=#{ics_escape(name)}:mailto:#{email}"
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
      Settings.boolean("SMTP_STARTTLS", true)
    end

    def smtp_ssl?
      Settings.boolean("SMTP_SSL", false)
    end

    def auth_method
      env_value("SMTP_AUTH", DEFAULT_AUTH.to_s).to_sym
    end

    def resend_enabled?
      Settings.boolean("RESEND_ENABLED", false) || !env_value("RESEND_API_KEY", "").empty?
    end

    def resend_from
      "#{from_label} <#{required_env("EMAIL_FROM")}>"
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
      Settings.value(name, fallback)
    end
  end
end
