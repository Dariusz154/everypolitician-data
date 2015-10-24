
# After generating the merged CSV, ensure that it contains what we need
# and is well-formed
#
# We don't need to check the raw source data as it may be overridden.

desc "Verify merged data"

namespace :verify do

  task :load => 'merge_sources:sources/merged.csv' do
    # plain CSV read — no need for the (much slower) csv_table remapping
    @csv = CSV.read('sources/merged.csv', headers: true, header_converters: :symbol)
  end

  task :check_data => :load do
    @csv.each do |r|
      abort "No `name` in #{r}" if r[:name].to_s.empty?
      r.to_hash.keys.select { |k| k.to_s.include? '_date' }.each do |d|
        next if r[d].nil? || r[d].empty?
        if r[d].match /^\d{4}$/ 
          warn "Short #{d} in #{r}" 
          #TODO: don't allow short dates
          next
        end
        abort "Badly formatted #{d} in #{r}" unless r[d].match /^\d{4}-\d{2}-\d{2}$/
        parsed_date = Date.parse(r[d]) rescue 'broken'
        abort "Invalid #{d} in #{r}" unless parsed_date.to_s == r[d]
      end
    end
  end  
end


