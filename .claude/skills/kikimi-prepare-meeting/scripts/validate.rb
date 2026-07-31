#!/usr/bin/env ruby
# frozen_string_literal: true

# Validate a Kikimi meeting profile before opening it in the app.
# Spec: docs/design/41-meeting-profiles.md (profile format), kikimi.md ch.9 and
# docs/design/34-simple-watchers.md (watcher file formats).
#
# Usage: ruby validate.rb <profile-id>
# Exit code: 0 = no errors (warnings allowed), 1 = errors found or usage error.

require "yaml"
require "json"

ID_RE = /\A[A-Za-z0-9-]+\z/
TRIGGER_RE = /\A(on_summary_update|on_session_end|on_manual|on_interval:\d+)\z/
INPUT_SCOPE_RE = /\A(summary|summary_and_recent(:\d+)?|full_refined)\z/
PROFILE_KEYS = %w[name description enabled_watchers participant_ids].freeze
SIMPLE_KEYS_REQUIRED = %w[kind id name trigger input_scope].freeze
SIMPLE_KEYS_FORBIDDEN = %w[schema view state_mode initial_state].freeze
FULL_KEYS_REQUIRED = %w[id name trigger state_mode input_scope schema view].freeze
STATE_MODES = %w[cumulative snapshot append_only].freeze
# Fixed summary schema (kikimi.md ch.8): top-level fields plus per-item fields.
SUMMARY_VARS = %w[title overview participants decisions action_items name is_last text task assignee due].freeze

@errors = []
@warnings = []

# Classic method definitions: the bundled macOS ruby is 2.6, which has no endless defs.
def error(msg)
  @errors << msg
end

def warning(msg)
  @warnings << msg
end

def load_config_dir(config, *keys, default:)
  value = keys.reduce(config) { |acc, key| acc.is_a?(Hash) ? acc[key] : nil }
  File.expand_path(value.is_a?(String) && !value.empty? ? value : default)
end

# Returns [frontmatter_hash_or_nil, body]. Reports a parse failure via error().
def split_frontmatter(path, text)
  unless text =~ /\A---\n(.*?)\n---\n?(.*)\z/m
    error("#{path}: frontmatter (--- ... ---) not found")
    return [nil, ""]
  end
  begin
    [YAML.safe_load(Regexp.last_match(1)) || {}, Regexp.last_match(2)]
  rescue Psych::Exception => e
    error("#{path}: frontmatter YAML parse failed: #{e.message.lines.first&.strip}")
    [nil, Regexp.last_match(2)]
  end
end

# Extract mustache tokens as [sigil, name] pairs. Sigil is "#", "^", "/" or "".
def mustache_tokens(text)
  text.scan(/\{\{([#^\/]?)\s*([A-Za-z0-9_.-]+)\s*\}\}/)
end

def check_section_balance(path, tokens)
  stack = []
  tokens.each do |sigil, name|
    case sigil
    when "#", "^" then stack << name
    when "/"
      if stack.last == name
        stack.pop
      else
        error("#{path}: mustache section mismatch: {{/#{name}}} closes {{#{stack.last ? "##{stack.last}" : "(nothing)"}}}")
        return
      end
    end
  end
  error("#{path}: unclosed mustache section(s): #{stack.join(", ")}") unless stack.empty?
end

# Collect every key name appearing anywhere in the schema declaration, plus
# is_<value> flags derived from enum[...] fields (injected by WatcherViewRenderer).
def schema_vocabulary(node, vocab = [])
  case node
  when Hash
    node.each do |key, value|
      vocab << key.to_s
      schema_vocabulary(value, vocab)
    end
  when Array
    node.each { |item| schema_vocabulary(item, vocab) }
  when String
    node.scan(/enum\[([^\]]*)\]/).each do |(values)|
      values.split(",").each { |v| vocab << "is_#{v.strip}" }
    end
  end
  vocab
end

def validate_watcher_file(path)
  frontmatter, body = split_frontmatter(path, File.read(path))
  return if frontmatter.nil?

  if frontmatter["kind"] == "simple"
    (SIMPLE_KEYS_REQUIRED - frontmatter.keys).each { |k| error("#{path}: simple watcher missing required key: #{k}") }
    (SIMPLE_KEYS_FORBIDDEN & frontmatter.keys).each { |k| error("#{path}: simple watcher must not declare: #{k}") }
    error("#{path}: simple watcher body (viewpoint prompt) is empty") if body.strip.empty?
  else
    (FULL_KEYS_REQUIRED - frontmatter.keys).each { |k| error("#{path}: watcher missing required key: #{k}") }
    if frontmatter["state_mode"] && !STATE_MODES.include?(frontmatter["state_mode"])
      error("#{path}: invalid state_mode: #{frontmatter["state_mode"]}")
    end
    error("#{path}: missing '# System' section") unless body =~ /^# System\s*$/
    error("#{path}: missing '# User' section") unless body =~ /^# User\s*$/
    if frontmatter["initial_state"].is_a?(String)
      begin
        JSON.parse(frontmatter["initial_state"])
      rescue JSON::ParserError => e
        error("#{path}: initial_state is not valid JSON: #{e.message.lines.first&.strip}")
      end
    end
    if frontmatter["schema"] && frontmatter["view"].is_a?(String)
      tokens = mustache_tokens(frontmatter["view"])
      check_section_balance(path, tokens)
      vocab = schema_vocabulary(frontmatter["schema"])
      tokens.each do |sigil, name|
        next if sigil == "/"
        root = name.split(".").first
        unless vocab.include?(root) || root.start_with?("is_")
          warning("#{path}: view references {{#{name}}} which is not declared in schema")
        end
      end
    end
  end

  id = frontmatter["id"]
  expected = File.basename(path, ".md")
  error("#{path}: id '#{id}' does not match filename '#{expected}'") if id.is_a?(String) && id != expected
  if frontmatter["trigger"].is_a?(String) && frontmatter["trigger"] !~ TRIGGER_RE
    error("#{path}: invalid trigger: #{frontmatter["trigger"]}")
  end
  if frontmatter["input_scope"].is_a?(String) && frontmatter["input_scope"] !~ INPUT_SCOPE_RE
    error("#{path}: invalid input_scope: #{frontmatter["input_scope"]}")
  end
end

def validate_summary_template(path)
  tokens = mustache_tokens(File.read(path))
  check_section_balance(path, tokens)
  tokens.each do |sigil, name|
    next if sigil == "/"
    unless SUMMARY_VARS.include?(name.split(".").first)
      error("#{path}: {{#{name}}} is not a summary schema field (schema is fixed; allowed: #{SUMMARY_VARS.join(", ")})")
    end
  end
end

# --- main ---

profile_id = ARGV[0]
abort("usage: validate.rb <profile-id>") if profile_id.nil? || profile_id.empty?

config_path = File.expand_path("~/.config/kikimi/config.yaml")
config = File.exist?(config_path) ? (YAML.safe_load(File.read(config_path)) || {}) : {}
profiles_dir = load_config_dir(config, "profiles", "dir", default: "~/.config/kikimi/profiles")
presets_dir = load_config_dir(config, "watchers", "presets_dir", default: "~/.config/kikimi/watchers")

error("profile id '#{profile_id}' must match [A-Za-z0-9-]+") unless profile_id =~ ID_RE
profile_dir = File.join(profiles_dir, profile_id)
abort("error: profile directory not found: #{profile_dir}") unless Dir.exist?(profile_dir)

manifest_path = File.join(profile_dir, "profile.yaml")
enabled = []
if File.exist?(manifest_path)
  begin
    manifest = YAML.safe_load(File.read(manifest_path)) || {}
    if manifest.is_a?(Hash)
      error("#{manifest_path}: 'name' is required and must be a string") unless manifest["name"].is_a?(String)
      warning("#{manifest_path}: 'name' is empty (UI falls back to the id)") if manifest["name"] == ""
      (manifest.keys - PROFILE_KEYS).each { |k| warning("#{manifest_path}: unknown key '#{k}' (ignored by the app)") }
      %w[enabled_watchers participant_ids].each do |key|
        value = manifest[key]
        next if value.nil?
        unless value.is_a?(Array) && value.all? { |v| v.is_a?(String) }
          error("#{manifest_path}: '#{key}' must be a list of strings")
        end
      end
      enabled = manifest["enabled_watchers"].is_a?(Array) ? manifest["enabled_watchers"].select { |v| v.is_a?(String) } : []
    else
      error("#{manifest_path}: top level must be a YAML mapping")
    end
  rescue Psych::Exception => e
    error("#{manifest_path}: YAML parse failed: #{e.message.lines.first&.strip}")
  end
else
  error("#{manifest_path}: profile.yaml is required (directories without it are excluded from listing)")
end

enabled.each do |watcher_id|
  error("profile.yaml: enabled watcher id '#{watcher_id}' must match [A-Za-z0-9-]+") unless watcher_id =~ ID_RE
  preset_path = File.join(presets_dir, "#{watcher_id}.md")
  if File.exist?(preset_path)
    validate_watcher_file(preset_path)
  else
    error("profile.yaml: enabled watcher '#{watcher_id}' has no preset file at #{preset_path}")
  end
end

# Profile-prefixed presets that exist but are not enabled are probably a generation slip.
Dir.glob(File.join(presets_dir, "#{profile_id}-*.md")).sort.each do |path|
  watcher_id = File.basename(path, ".md")
  warning("#{path}: profile-prefixed watcher is not listed in enabled_watchers") unless enabled.include?(watcher_id)
end

summary_template = File.join(profile_dir, "summary_template.md")
if File.exist?(summary_template)
  validate_summary_template(summary_template)
else
  warning("#{summary_template}: absent — the global default template will be used (fine if intended)")
end
context_path = File.join(profile_dir, "context.md")
unless File.exist?(context_path)
  warning("#{context_path}: absent — the global common context will be used (fine if intended)")
end

@warnings.each { |w| puts "warning: #{w}" }
@errors.each { |e| puts "error: #{e}" }
if @errors.empty?
  puts "OK: profile '#{profile_id}' passed validation (#{@warnings.size} warning(s))"
else
  puts "FAILED: #{@errors.size} error(s), #{@warnings.size} warning(s)"
  exit 1
end
