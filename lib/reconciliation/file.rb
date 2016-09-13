require 'csv'

module Reconciliation
  class File
    def initialize(pathname)
      @pathname = pathname
    end

    def csv
      @csv ||= CSV.table(pathname, converters: nil)
    end

    def to_h
      csv.map { |r| [r[:id], r[:uuid]] }.to_h
    end

    def write!(h)
      headers = %w(id uuid).to_csv
      rows    = h.sort_by { |_, v| v }.map(&:to_csv).join
      pathname.write(headers + rows)
    end

    private

    attr_reader :pathname
  end
end
