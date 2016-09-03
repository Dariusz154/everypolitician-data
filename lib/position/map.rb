# TODO: move this to its own file
class PositionMap
  # Which Wikidata Positions we're interested in, and how to group them

  def initialize(pathname:)
    @pathname = pathname
  end

  def to_json
    return empty_filter unless pathname.exist?
    raw_json
  end

  def type(pid)
    type_lookup[pid]
  end

  def include_ids
    to_json[:include].values.flatten.map { |p| p[:id] }.to_set
  end

  def exclude_ids
    to_json[:exclude].values.flatten.map { |p| p[:id] }.to_set
  end

  def known_ids
    include_ids + exclude_ids
  end

  def cabinet_ids
    (to_json[:include][:cabinet] || []).map { |p| p[:id] }.to_set
  end

  private

  attr_reader :pathname

  def empty_filter
    { exclude: { self: [], other: [] }, include: { self: [], other_legislatures: [], cabinet: [], executive: [], party: [], other: [] } }
  end

  def raw_json
    @json ||= json5_parse(pathname.read).each do |_s, fs|
      fs.each { |_, fss| fss.each { |f| f.delete :count } }
    end
  end

  # TODO: move this to somewhere more generally useful
  def json5_parse(data)
    # read with JSON5 to be more liberal about trailing commas.
    # But that doesn't have a 'symbolize_names' so rountrip through JSON
    JSON.parse(JSON5.parse(data).to_json, symbolize_names: true)
  end

  def type_lookup
    @type ||= raw_json.values.flatten.flat_map do |i|
      i.flat_map do |type, items|
        items.map { |item| [item[:id], type] }
      end
    end.to_h
  end
end
