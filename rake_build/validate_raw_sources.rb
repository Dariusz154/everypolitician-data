
# Ensure that all the source CSV files are well-formed

require 'csvlint'

desc 'validate raw CSV sources'
namespace :csvlint do
  task :validate do
    FileList['sources/**/*.csv'].each do |file|
      validator = Csvlint::Validator.new(File.new(file))
      next if validator.valid?

      abort "Problem linting %s:\n%s" % [
        file,
        validator.errors.map { |e| "\t#{e.type} at line #{e.row}" }.join("\n"),
      ]
    end
  end
end
