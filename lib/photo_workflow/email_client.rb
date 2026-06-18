require "net/smtp"
require "time"

module PhotoWorkflow
  class EmailClient
    DEFAULT_PORT = 587
    DEFAULT_AUTH = :plain
    EMAIL_PATTERN = /[A-Z0-9._%+\-]+@[A-Z0-9.\-]+\.[A-Z]{2,}/i.freeze

    def enabled?
      ENV.fetch("EMAIL_ENABLED", "false").casecmp("true").zero?
    end

    def notify_event_created(event:, card:)
      return unless enabled?

      recipient = recipient_for(event)
      unless recipient
        warn "Email notification skipped for #{event.fetch("summary", event.fetch("id"))}: missing client email"
        return
      end

      deliver(
        to: recipient,
        subject: subject_for(event),
        body: body_for(event, card)
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

    def deliver(to:, subject:, body:)
      message = [
        "From: #{from_label} <#{required_env("EMAIL_FROM")}>",
        "To: #{to}",
        "Subject: #{encode_subject(subject)}",
        "MIME-Version: 1.0",
        "Content-Type: text/plain; charset=UTF-8",
        "",
        body
      ].join("\r\n")

      smtp = Net::SMTP.new(required_env("SMTP_HOST"), env_integer("SMTP_PORT", DEFAULT_PORT))
      smtp.enable_starttls_auto if starttls?
      smtp.start(required_env("SMTP_DOMAIN"), required_env("SMTP_USERNAME"), required_env("SMTP_PASSWORD"), auth_method) do |connection|
        connection.send_message(message, required_env("EMAIL_FROM"), to)
      end
    end

    def subject_for(event)
      ENV.fetch("EMAIL_SUBJECT_PREFIX", "Confirmacao de ensaio") + " - " + event.fetch("summary", "")
    end

    def body_for(event, card)
      template = ENV["EMAIL_BODY_TEMPLATE"]
      return interpolate(template, event, card) if template && !template.empty?

      [
        "Ola!",
        "",
        "Seu ensaio foi agendado com sucesso.",
        "",
        "Ensaio: #{event.fetch("summary", "")}",
        "Data: #{formatted_time(event.fetch("start", {}))}",
        optional_line("Local", event["location"]),
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
      ENV.fetch("EMAIL_FROM_NAME", "Photo Workflow")
    end

    def starttls?
      ENV.fetch("SMTP_STARTTLS", "true").casecmp("true").zero?
    end

    def auth_method
      ENV.fetch("SMTP_AUTH", DEFAULT_AUTH.to_s).to_sym
    end

    def env_integer(name, fallback)
      ENV.fetch(name, fallback).to_i
    end

    def required_env(name)
      ENV.fetch(name) { raise "Missing ENV #{name}" }
    end
  end
end
