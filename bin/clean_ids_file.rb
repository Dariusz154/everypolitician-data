require 'csv'
require 'pry'

# Clean out dead IDs from an id→uuid mapping file

map_filename = ARGV.first or abort "Usage: #$0 <filename>"
mapping = CSV.table(map_filename)

source = CSV.table(map_filename.sub('-ids.csv','.csv'))
source_ids = source.map { |r| r[:id] }.uniq.sort

map_ids = mapping.map { |r| r[:id] }.uniq.sort

can_remove = (map_ids - source_ids).to_set

abort "Nothing to clean" if can_remove.empty?

header = mapping.headers.to_csv
data   = mapping.reject { |r| can_remove.include? r[:id] }.map(&:to_csv).join

File.write(map_filename, header + data)
