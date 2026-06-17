require "fileutils"
require "json"

module PhotoWorkflow
  class StateStore
    def initialize(path: ENV.fetch("STATE_PATH", "data/calendar_event_syncs.json"))
      @path = path
    end

    def all
      return {} unless File.exist?(path)

      JSON.parse(File.read(path))
    end

    def save(state)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, JSON.pretty_generate(state.sort.to_h) + "\n")
    end

    private

    attr_reader :path
  end
end

