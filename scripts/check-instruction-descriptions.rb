#!/usr/bin/env ruby
# frozen_string_literal: true

require "digest"
require "json"
require "set"

def active_asciidoc(text)
  in_comment_block = false
  text.each_line.each_with_object([]) do |line, active|
    if line.strip == "////"
      in_comment_block = !in_comment_block
      next
    end
    next if in_comment_block || line.lstrip.start_with?("//")

    active << line
  end.join
end

root = File.expand_path("..", __dir__)
archive_dir = ["legacy", %w[u db].join].join("-")
instructions_path = File.join(root, "src", "instructions.adoc")
allocations_path = File.join(root, "src", "instruction-encoding-allocations.adoc")
baseline_path = File.join(root, "ref", "ame-instruction-baseline.json")
audit_path = File.join(root, "docs", "migration", "ame-prose-migration-audit.md")
errors = []

expected_baseline_hash = "05533ab50d606fea94e23861e9948ac323840fd2c5a51e15c9655b327a90a073"
actual_baseline_hash = Digest::SHA256.file(baseline_path).hexdigest
unless actual_baseline_hash == expected_baseline_hash
  errors << "baseline snapshot hash is #{actual_baseline_hash}, expected #{expected_baseline_hash}"
end
baseline_document = JSON.parse(File.read(baseline_path))
unless baseline_document["prose_semantics_baseline"] == "reviewed traditional-vector-style cutover"
  errors << "baseline snapshot does not identify the reviewed prose semantics baseline"
end
expected_commit = "b97c6c4656525ee06aeb9600021b1debc0a76233"
unless baseline_document["baseline_commit"] == expected_commit
  errors << "baseline snapshot identifies #{baseline_document['baseline_commit']}, expected #{expected_commit}"
end
baseline = baseline_document.fetch("instructions")
expected_audit_operations = baseline_document.fetch("audit_operations", {})

attributes = {}
File.foreach(allocations_path) do |line|
  match = line.match(/^:([a-z0-9-]+):\s+(\S+)$/)
  attributes[match[1]] = match[2] if match
end

instructions = active_asciidoc(File.read(instructions_path))
categories = {}
current_category = nil
instructions.split("\n<<<\n", 2).first.each_line do |line|
  current_category = Regexp.last_match(1) if line.match(/^(.+)::$/)
  if line.match(/^a\| `([^\s`]+)/)
    name = Regexp.last_match(1)
    errors << "#{name}: duplicate category entry" if categories.key?(name)
    categories[name] = current_category
  end
end

sections = instructions.scan(/^\[#(ame:doc:inst:[^\]]+)\]\n=== `([^`]+)`\n(.*?)(?=^<<<\s*$|\z)/m)
errors << "instruction coverage is #{sections.length}/141" unless sections.length == 141

programming_model = active_asciidoc(File.read(File.join(root, "src", "programming_model.adoc")))
operand_class_table = programming_model[/\[\[ame-common-operand-classes\]\].*?^\|===\n(.*?)^\|===/m, 1]
if operand_class_table.nil?
  errors << "missing shared operand-class requirements table"
  operand_class_tokens = Set.new
else
  operand_class_tokens = operand_class_table.scan(/`([^`]+)`/).flatten.to_set
end

primary_contract = {
  "Resource Management" => "ame-common-state-access",
  "Datatype Management" => "ame-common-datatype-support",
  "Elementwise Arithmetic" => "ame-common-arithmetic",
  "Bitwise" => "ame-common-arithmetic",
  "Compare and Predication" => "ame-common-arithmetic",
  "Permutation" => "ame-common-structural",
  "Register move / data conversion" => "ame-common-register-groups",
  "Elementwise Math Functions" => "ame-common-arithmetic",
  "Memory" => "ame-common-memory",
  "State Management" => "ame-common-register-groups",
  "Matrix Multiply" => "ame-common-matmul",
  "Reduction" => "ame-common-structural"
}
data_scalar_categories = Set.new([
  "Elementwise Arithmetic",
  "Bitwise",
  "Compare and Predication",
  "Elementwise Math Functions"
])
control_scalar_names = Set.new(%w[
  mldexp.ew.x
  mldexpacc.ew.x
  msll.ew.x
  msra.ew.x
  msrl.ew.x
])

current_identity = []
active_sections_by_name = {}
sections.each_with_index do |(anchor, name, section), index|
  active_section = active_asciidoc(section)
  active_sections_by_name[name] = active_section
  category = categories[name]
  errors << "#{name}: missing instruction-list category" unless category

  %w[Synopsis Mnemonic Encoding Description Operation].each do |label|
    count = active_section.scan(/^#{label}::$/).length
    errors << "#{name}: expected one #{label} block, found #{count}" unless count == 1
  end
  errors << "#{name}: Operation is not a language-neutral source block" unless active_section.match?(/^Operation::\n\+\n\[source\]\n----\n.+?\n----/m)

  description_raw = active_section[/^Description::\n(.*?)(?=^Operation::$)/m, 1]
  operation_raw = active_section[/^Operation::\n\+\n\[source\]\n----\n(.+?)\n----/m, 1]
  if description_raw&.match?(/^\s+.*`/)
    errors << "#{name}: indented description pseudocode contains literal inline-code delimiters"
  end
  if operation_raw&.match?(/`|\\|\^[^\n^]+\^|~[^\n~]+~/)
    errors << "#{name}: Operation source block contains AsciiDoc presentation markup"
  end

  contract = name == "fence.ame" ? "ame-common-ordering" : primary_contract[category]
  if contract.nil?
    errors << "#{name}: category #{category.inspect} has no common-contract mapping"
  elsif !active_section.include?("<<#{contract}>>")
    errors << "#{name}: missing required common contract #{contract}"
  end

  data_scalar = name.end_with?(".ew.x") && data_scalar_categories.include?(category) &&
                !control_scalar_names.include?(name)
  if data_scalar && !active_section.include?("<<ame-common-datatype-support>>")
    errors << "#{name}: data scalar does not reference the scalar datatype-conversion contract"
  end
  control_scalar = name.end_with?(".ew.x") && !data_scalar
  if control_scalar
    unless active_section.match?(/does\s+not read/)
      errors << "#{name}: fixed control scalar is confused with a datatype-converted data scalar"
    end
  end

  operand_class_exempt = ["Resource Management", "Datatype Management", "Memory"].include?(category) ||
                         name == "fence.ame" || name.match?(/^mmove(?:8|16|32|64)\./)
  class_family_name = name.end_with?(".ew.x") ? name.sub(/\.ew\.x\z/, ".ew") : name
  unless operand_class_exempt || operand_class_tokens.include?(name) || operand_class_tokens.include?(class_family_name)
    errors << "#{name}: no entry in the shared operand-class requirements table"
  end

  raw = section.lines.find { |line| line.start_with?('{"reg":') }.to_s.strip
  resolved = raw.gsub(/\{([a-z0-9-]+)\}/) do
    key = Regexp.last_match(1)
    errors << "#{name}: unknown encoding attribute #{key}" unless attributes.key?(key)
    attributes.fetch(key, "0")
  end
  position = 0
  mask = 0
  match_value = 0
  resolved.scan(/"bits":(\d+),"name":\s*("[^"]+"|0x[0-9a-f]+|\d+)/) do |width_text, token|
    width = width_text.to_i
    unless token.start_with?('"')
      value = token.start_with?("0x") ? token.to_i(16) : token.to_i
      mask |= ((1 << width) - 1) << position
      match_value |= value << position
    end
    position += width
  end
  dest_fixed = (mask & 0x00000f80) == 0x00000f80
  src1_fixed = (mask & 0x000f8000) == 0x000f8000
  src2_fixed = (mask & 0x01f00000) == 0x01f00000
  format_name = if !src2_fixed
                  "R3"
                elsif !src1_fixed
                  "R2"
                elsif !dest_fixed
                  "R1"
                else
                  "Fixed"
                end
  current_identity << {
    "order" => index + 1,
    "name" => name,
    "anchor" => anchor,
    "category" => category,
    "synopsis" => section[/^Synopsis::\n([^\n]+)/, 1],
    "mnemonic" => section[/^Mnemonic::\n`([^`]+)`/, 1],
    "description" => description_raw&.lines&.map(&:strip)&.reject(&:empty?)&.join("\n"),
    "operation" => operation_raw&.lines&.map(&:strip)&.reject(&:empty?)&.join("\n"),
    "wavedrom" => raw,
    "resolved_wavedrom" => resolved,
    "format" => format_name,
    "mask" => format("0x%08x", mask),
    "match" => format("0x%08x", match_value)
  }
end

{
  "agettyp" => [/zero_extend_XLEN\(Ad\[ad\]\)/, "zero-extended accumulator datatype read"],
  "asettyp" => [/Ad\[ad\] = X\[xs1\]\[31:0\].*raw_bits\(Acc\[ad\]\) = 0/m, "32-bit datatype write and raw accumulator clear"],
  "ame.acquire" => [/descriptor = X\[xs\]/, "acquisition-descriptor interpretation"],
  "mgettyp" => [/zero_extend_XLEN\(Md\[ms1\]\)/, "zero-extended M datatype read"],
  "msettyp" => [/new_dtype = X\[xs1\]\[31:0\].*raw_bits\(M\[md \.\. md\+group_size-1\]\) = 0/m, "32-bit datatype write and whole-group raw M-register clear"],
  "mbcast.m.x" => [/greater than XLEN.*zero-extended/m, "explicit scalar-ingress widening rule"],
  "mls" => [/AME_MATRIX_REGISTER_SIZE \/ 8/, "raw M-register byte count"],
  "mss" => [/AME_MATRIX_REGISTER_SIZE \/ 8/, "raw M-register byte count"],
  "mls.cm" => [/total_bytes = ceil\(pack_factor \* AME_NELEM \* sizeof\(Md\[md\]\) \/ 8\)/, "column-major byte-rounded transfer size"],
  "mls.rm" => [/total_bytes = ceil\(pack_factor \* AME_NELEM \* sizeof\(Md\[md\]\) \/ 8\)/, "row-major byte-rounded transfer size"],
  "mss.cm" => [/total_bytes = ceil\(pack_factor \* AME_NELEM \* sizeof\(Md\[ms1\]\) \/ 8\)/, "column-major byte-rounded transfer size"],
  "mss.rm" => [/total_bytes = ceil\(pack_factor \* AME_NELEM \* sizeof\(Md\[ms1\]\) \/ 8\)/, "row-major byte-rounded transfer size"],
  "mls.st" => [/element_bytes = ceil\(sizeof\(Md\[md\]\) \/ 8\)/, "strided byte alignment"],
  "mls.tst" => [/element_bytes = ceil\(sizeof\(Md\[md\]\) \/ 8\)/, "transposed-strided byte alignment"],
  "mss.st" => [/element_bytes = ceil\(sizeof\(Md\[ms1\]\) \/ 8\)/, "strided byte alignment"],
  "mss.tst" => [/element_bytes = ceil\(sizeof\(Md\[ms1\]\) \/ 8\)/, "transposed-strided byte alignment"],
  "mcolbcast.ew.x" => [/low 32 bits/, "U32 column-index width"],
  "mrowbcast.ew.x" => [/low 32 bits/, "U32 row-index width"],
  "mcolshift.ew.x" => [/low 32 bits/, "S32 column-offset width"],
  "mrowshift.ew.x" => [/low 32 bits/, "S32 row-offset width"],
  "mpack.ew.x" => [/low 32 bits/, "U32 packed-slot index width"],
  "munpack.ew.x" => [/low 32 bits/, "U32 packed-slot index width"]
}.each do |name, (pattern, description)|
  section = active_sections_by_name.fetch(name, "")
  errors << "#{name}: missing #{description}" unless section.match?(pattern)
end

{
  /data-source element width/ => "source-width shift rule",
  /scalar\s+datatype is wider than XLEN, the X-register bit pattern is zero-extended/m => "data-scalar widening rule",
  /`mcolunzip\.ew`, `mcolzip\.ew`, `mrowunzip\.ew`, and\s+`mrowzip\.ew` are also\s+explicit fixed-shape exceptions/m => "zip/unzip fixed-shape exception",
  /`D1`\s+occupies the\s+consecutive\s+M\s+registers immediately following `D0`/m => "zip/unzip consecutive destination-operand placement",
  /The common datatype size is no smaller than `AME_UNIT_DATATYPE_SIZE`; packed\s+datatypes are not supported/m => "Permutation unit-or-wide datatype rule",
  /The opaque `mls` and `mss` instructions do not inspect `Md`/ => "opaque load/store datatype exemption",
  /Elements are packed\s+back-to-back as E-bit fields/m => "typed memory bit packing",
  /load ignores the unused high bits.*store writes those unused high bits as zero/m => "partial-byte load/store rule",
  /Segment `i` contains `P \* N \* E` bits/ => "strided segment size rule",
  /Segment `sq \* N \+ j` contains `N \* E` bits/ => "transposed-strided segment size rule",
  /`base` is\s+the unsigned XLEN-bit value `X\[xs1\]`, and `stride` is the unsigned XLEN-bit\s+value `X\[xs2\]`/m => "strided address operand widths",
  /`\(base \+ seg \* stride\) modulo 2\^XLEN`/ => "strided modulo-XLEN address arithmetic",
  /segments\s+in ascending segment-number order.*later segment therefore wins/m => "overlapping strided-store ordering",
  /lowest-addressed\s+byte transfers physical bits 7:0/m => "opaque memory byte order",
  /Checks occur in the following architectural order/ => "memory exception-priority rule",
  /most\s+significant bit of the raw predicate-element encoding/m => "raw sign-bit predicate rule",
  /low 32 raw bits of each matrix-index element/m => "U32 matrix-index rule",
  /true comparison produces all one bits/ => "comparison result-bit rule",
  /derived accumulator span.*checked after the operation\s+tuple is supported/m => "packed accumulator span validation",
  /zero-extended or low-bit truncated/ => "fixed scalar-exponent width rule",
  /`mmulacc\.ew\.x`/ => "destination-as-source scalar fused-operation rule",
  /`mcolscatadd\.ew`, `mrowscatadd\.ew`/ => "scatter-add floating-point rule",
  /`mcolscatmax\.ew`, `mrowscatmax\.ew`/ => "scatter-max floating-point rule",
  /Scatter source elements are processed in ascending logical row-major order/ => "scatter collision ordering rule",
  /prefix or reduction fold is seeded from the first source element/ => "prefix/reduction seed rule",
  /transposes each `N x N` logical square/ => "dimensionally valid transposed matrix formation",
  /seeds each dot product with the accumulator datatype's semantic\s+additive zero/m => "overwriting matrix semantic-zero seed",
  /`NV` is set for a signaling NaN or an invalid operation/ => "floating-point invalid-flag rule",
  /`UF` is set when the result is tiny after rounding and inexact/ => "floating-point underflow-flag rule",
  /`mhdiff\.ew\.x`, `mmean\.ew`/ => "scalar half-difference/mean integer rounding rule"
}.each do |pattern, description|
  errors << "programming_model.adoc: missing #{description}" unless programming_model.match?(pattern)
end

if current_identity != baseline
  keys = %w[order name anchor category synopsis mnemonic description operation wavedrom resolved_wavedrom format mask match]
  [current_identity.length, baseline.length].min.times do |index|
    keys.each do |key|
      next if current_identity[index][key] == baseline[index][key]

      errors << "baseline identity mismatch at instruction #{index + 1} #{key}: " \
                "#{current_identity[index][key].inspect} != #{baseline[index][key].inspect}"
    end
  end
end

root_document_path = File.join(root, "src", "riscv-spec.adoc")
required_root_includes = %w[
  contributors.adoc
  intro.adoc
  programming_model.adoc
  state.adoc
  datatypes.adoc
  parameters.adoc
  examples.adoc
  instructions.adoc
  glossary.adoc
  base-isa-anchors.adoc
]
root_include_counts = Hash.new(0)
conditional_depth = 0
active_asciidoc(File.read(root_document_path)).each_line.with_index(1) do |line, line_number|
  if line.match?(/^\s*(?:ifdef|ifndef|ifeval)::/)
    conditional_depth += 1
    next
  end
  if line.match?(/^\s*endif::/)
    conditional_depth -= 1
    errors << "riscv-spec.adoc: unmatched endif at line #{line_number}" if conditional_depth.negative?
    conditional_depth = 0 if conditional_depth.negative?
    next
  end

  match = line.match(/^\s*include::([^\[]+)\[([^\]]*)\]/)
  next unless match

  include_name = match[1]
  next unless required_root_includes.include?(include_name)

  root_include_counts[include_name] += 1
  unless match[2].strip.empty?
    errors << "riscv-spec.adoc: required include #{include_name} must not select or filter content at line #{line_number}"
  end
  if conditional_depth.positive?
    errors << "riscv-spec.adoc: required include #{include_name} is conditional at line #{line_number}"
  end
end
errors << "riscv-spec.adoc: unterminated conditional directive" unless conditional_depth.zero?
required_root_includes.each do |include_name|
  count = root_include_counts[include_name]
  errors << "riscv-spec.adoc: required include #{include_name} must appear exactly once, found #{count}" unless count == 1

  include_path = File.join(root, "src", include_name)
  next unless File.file?(include_path)

  include_text = active_asciidoc(File.read(include_path))
  if include_text.match?(/^\s*(?:ifdef|ifndef|ifeval|else|endif)::/)
    errors << "#{include_name}: conditional directives are not permitted in required AME publication material"
  end
end

def include_closure(path, seen, errors)
  absolute = File.expand_path(path)
  return [] if seen.include?(absolute)

  seen << absolute
  unless File.file?(absolute)
    errors << "missing included file #{absolute}"
    return []
  end
  files = [absolute]
  active_asciidoc(File.read(absolute)).each_line do |line|
    match = line.match(/^\s*include::([^\[]+)\[[^\]]*\]/)
    next unless match

    files.concat(include_closure(File.expand_path(match[1], File.dirname(absolute)), seen, errors))
  end
  files
end

closure = include_closure(File.join(root, "src", "riscv-spec.adoc"), Set.new, errors)
if closure.any? { |path| path.include?(File.join("formal", archive_dir)) }
  errors << "historical IDL archive is reachable from the published document"
end
errors << "retired src/functions.adoc remains in the published include closure" if closure.any? { |path| File.basename(path) == "functions.adoc" }

forbidden = {
  "[source,idl" => "IDL source block",
  "AmeOperation::" => "IDL operation enum",
  "$encoding" => "generated encoding variable",
  "pass:[" => "IDL AsciiDoc escape",
  "Bits<" => "IDL bit-vector type",
  "ame:doc:func:" => "legacy helper anchor or reference",
  "NumPy Equivalent::" => "NumPy semantic block",
  "Decode Variables::" => "generated decode-variable block"
}
closure.each do |path|
  text = File.read(path)
  forbidden.each do |marker, description|
    errors << "#{path.sub(root + '/', '')}: published closure contains #{description} (#{marker})" if text.include?(marker)
  end
end

former_helper_anchor = /\[#ame:doc:func:(ame_|read_memory_ame|write_memory_ame|sqrt|min)/
%w[instructions.adoc programming_model.adoc].each do |filename|
  path = File.join(root, "src", filename)
  errors << "#{filename}: legacy helper anchor remains" if File.read(path).match?(former_helper_anchor)
end

required_norm_anchors = %w[
  norm:ame_nsq_1d
  norm:ame_nsq_structural
  norm:ame_nsq_matmul
  norm:ame_register_group_overlap
  norm:ame_source_snapshot
  norm:ame_atomic_register_writeback
  norm:ame_register_exception_atomicity
  norm:ame_op_supported_contract
  norm:ame_op_supported_defined_result
  norm:ame_op_precondition
  norm:ame_op_result_width
  norm:ame_fp_special_values
]
published = closure.map { |path| File.read(path) }.join("\n")
active_published = active_asciidoc(published)
unless active_published.include?("[#ame:doc:param:AME_MAX_INT_DTYPE]") &&
       active_published.include?("greatest element width") &&
       active_published.include?("If it is absent, every `mldexp.ew.x`")
  errors << "published document does not define AME_MAX_INT_DTYPE"
end
required_norm_anchors.each do |anchor|
  count = active_published.scan(/^\[##{Regexp.escape(anchor)}\]/).length
  errors << "published document must contain exactly one active normative anchor #{anchor}, found #{count}" unless count == 1
end

if active_published.match?(/\b[A-Z][A-Z0-9]*1D\b/) ||
   active_published.match?(/\bm[a-z0-9_.]*\.1d(?:\.x)?\b/)
  errors << "published document contains a retired internal 1D operation name"
end
errors << "published document contains a retired conceptual NumPy marker" if active_published.include?("conceptual:")
errors << "published document uses +/-, which breaks inline AsciiDoc rendering; use ±" if active_published.include?("+/-")

archive_hashes = {
  "instructions-idl.adoc" => "7e103b393e5e6e7e762757b890d7afa9a51eca3b4a046567803e807070d49680",
  "functions-idl.adoc" => "140e50c2d5bb24f5de88fec1a71ac15c29cc2b6f8084d084cfd7024c3d8c1b07",
  "instruction-encoding-allocations.adoc" => "9a3748a14613d05e44c7a70810f0b1747df2c75125e46e98ed0725fada929f30"
}
archive_hashes.each do |filename, expected|
  path = File.join(root, "formal", archive_dir, filename)
  actual = File.file?(path) ? Digest::SHA256.file(path).hexdigest : "missing"
  errors << "historical archive hash mismatch for #{filename}: #{actual}" unless actual == expected
end

archive_readme = File.read(File.join(root, "formal", archive_dir, "README.md"))
readme_requirements = [
  "historical, non-normative",
  "Repository: `riscv/riscv-attached-matrix-extension`",
  "Baseline commit: `#{expected_commit}`",
  "Baseline tag: `v0.5`"
]
archive_hashes.each do |filename, expected|
  readme_requirements << "| `#{filename}` | `#{expected}` |"
end
readme_requirements.each do |fragment|
  errors << "historical archive README lost provenance fragment #{fragment.inspect}" unless archive_readme.include?(fragment)
end

audit = File.read(audit_path)
errors << "migration audit does not record 141/141 instructions" unless audit.include?("Instruction coverage (141/141)")
errors << "migration audit does not record 90/90 helpers" unless audit.include?("Helper coverage (90/90)")
errors << "migration audit does not record 12/12 published normative anchors" unless audit.include?("Published normative-anchor coverage (12/12)")
instruction_audit = audit[/## Instruction coverage.*?(?=^## Helper coverage)/m].to_s
helper_audit = audit[/## Helper coverage.*?(?=^## Published normative-anchor coverage)/m].to_s
norm_audit = audit[/## Published normative-anchor coverage.*?(?=^## Corrections)/m].to_s
instruction_row_pattern = /^\| `(?<name>[^`]+)` \| (?<legacy_line>\d+) \| `(?<anchor>[^`]+)` \| (?<category>[^|]+?) \| `(?<mnemonic>[^`]+)` \| `(?<operation>[^`]*)` \| `(?<contract>[^`]+)` \| (?<correction>[^|]+?) \| (?<status>[^|]+?) \|\s*$/
audited_instruction_rows = {}
instruction_audit.each_line do |line|
  next unless line.start_with?("| `")

  match = line.match(instruction_row_pattern)
  unless match
    errors << "migration audit has a malformed instruction row: #{line.strip}"
    next
  end
  name = match[:name]
  errors << "migration audit has duplicate instruction row #{name}" if audited_instruction_rows.key?(name)
  audited_instruction_rows[name] = match.named_captures
end
audited_instruction_names = audited_instruction_rows.keys
audited_helper_names = helper_audit.scan(/^\| `([^`]+)` \|/).flatten
audited_norm_anchors = norm_audit.scan(/^\| `(norm:[^`]+)` \|/).flatten
expected_instruction_names = baseline.map { |entry| entry.fetch("name") }
unless expected_audit_operations.keys == expected_instruction_names
  errors << "baseline audit-operation rows do not exactly match the 141-entry instruction baseline"
end
archive_functions = File.read(File.join(root, "formal", archive_dir, "functions-idl.adoc"))
expected_helper_names = archive_functions.scan(/^=== `([^`]+)`/).flatten
expected_legacy_norm_anchors = archive_functions.scan(/^\[#(norm:[^\]]+)\]/).flatten
expected_published_norm_anchors = required_norm_anchors
errors << "migration audit instruction rows do not exactly match the 141-entry baseline" unless audited_instruction_names == expected_instruction_names
errors << "migration audit helper rows do not exactly match the 90-entry archive" unless audited_helper_names == expected_helper_names
errors << "migration audit normative-anchor rows do not exactly match the 12 published anchors" unless audited_norm_anchors == expected_published_norm_anchors
unless expected_legacy_norm_anchors.all? { |anchor| audited_norm_anchors.include?(anchor) }
  errors << "migration audit omits a normative anchor from the legacy helper archive"
end
correction_expectations = expected_instruction_names.to_h { |name| [name, "-"] }
correction_expectations.merge!(
  "madd.ew" => "AME-MIG-001",
  "mls" => "AME-MIG-002, AME-MIG-007",
  "mls.cm" => "AME-MIG-002",
  "mls.rm" => "AME-MIG-002",
  "mls.st" => "AME-MIG-002",
  "mls.tst" => "AME-MIG-002",
  "mss" => "AME-MIG-002, AME-MIG-007",
  "mss.cm" => "AME-MIG-002",
  "mss.rm" => "AME-MIG-002",
  "mss.st" => "AME-MIG-002",
  "mss.tst" => "AME-MIG-002",
  "mldexp.ew.x" => "AME-MIG-006",
  "mldexpacc.ew.x" => "AME-MIG-006",
  "mmul.2d" => "AME-MIG-003",
  "mmulat.2d" => "AME-MIG-003, AME-MIG-005",
  "mmulatacc.2d" => "AME-MIG-005",
  "mmulbt.2d" => "AME-MIG-003, AME-MIG-005",
  "mmulbtacc.2d" => "AME-MIG-005",
  "mmulneg.2d" => "AME-MIG-003",
  "mrowunzip.ew" => "AME-MIG-004",
  "mrowzip.ew" => "AME-MIG-004"
)
legacy_instruction_lines = {}
legacy_instructions_path = File.join(root, "formal", archive_dir, "instructions-idl.adoc")
File.foreach(legacy_instructions_path).with_index(1) do |line, line_number|
  match = line.match(/^\[#(ame:doc:inst:[^\]]+)\]$/)
  legacy_instruction_lines[match[1]] = line_number.to_s if match
end
# Prose anchors renamed after the archive freeze keep their provenance through
# the frozen legacy anchor.
renamed_legacy_anchors = {
  "ame:doc:inst:mcolscatadd_ew" => "ame:doc:inst:mscatadd_row",
  "ame:doc:inst:mrowscatadd_ew" => "ame:doc:inst:mscatadd_col",
  "ame:doc:inst:mcolscatmax_ew" => "ame:doc:inst:mscatmax_row",
  "ame:doc:inst:mrowscatmax_ew" => "ame:doc:inst:mscatmax_col"
}
correction_expectations.each do |name, correction|
  row = audited_instruction_rows[name]
  baseline_entry = baseline.find { |entry| entry.fetch("name") == name }
  next unless row && baseline_entry

  expected_contract = name == "fence.ame" ? "ame-common-ordering" : primary_contract[baseline_entry.fetch("category")]
  {
    "legacy_line" => legacy_instruction_lines[renamed_legacy_anchors.fetch(baseline_entry.fetch("anchor"), baseline_entry.fetch("anchor"))],
    "anchor" => baseline_entry.fetch("anchor"),
    "category" => baseline_entry.fetch("category"),
    "mnemonic" => baseline_entry.fetch("mnemonic"),
    "operation" => expected_audit_operations[name],
    "contract" => expected_contract,
    "correction" => correction,
    "status" => "Ready"
  }.each do |field, expected|
    actual = row[field]
    errors << "migration audit row #{name} #{field} is #{actual.inspect}, expected #{expected.inspect}" unless actual == expected
  end
end
%w[AME-MIG-001 AME-MIG-002 AME-MIG-003 AME-MIG-004 AME-MIG-005 AME-MIG-006 AME-MIG-007].each do |correction|
  errors << "migration audit does not record correction #{correction}" unless audit.include?("### #{correction}:")
end

abort "instruction-description validation failed:\n  #{errors.join("\n  ")}" unless errors.empty?

puts "checked 141/141 prose instruction pages against baseline #{expected_commit[0, 12]}: " \
     "stable anchors/order/categories/synopses/mnemonics/encodings, complete common contracts and operand classes, " \
     "description/operation semantics, fully cross-checked migration audit, unconditional root publication, " \
     "12/12 published normative anchors, " \
     "frozen archive, and no IDL/NumPy markers in the include closure"
