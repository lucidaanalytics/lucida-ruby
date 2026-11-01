# frozen_string_literal: true

Gem::Specification.new do |s|
  s.name = "lucida"
  s.version = "0.1.0"
  s.summary = "Lucida server SDK: capture, batch, identify, local flag evaluation"
  s.license = "Apache-2.0"
  s.homepage = "https://github.com/lucidaanalytics/lucida-ruby"
  s.metadata = { "source_code_uri" => "https://github.com/lucidaanalytics/lucida-ruby", "bug_tracker_uri" => "https://github.com/lucidaanalytics/lucida-ruby/issues", "rubygems_mfa_required" => "true" }
  s.authors = ["Lucida"]
  s.required_ruby_version = ">= 3.1"
  s.files = Dir["lib/**/*.rb"]
end
