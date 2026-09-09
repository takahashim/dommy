# frozen_string_literal: true

# Static introspection of the JS-visible surface of a Dommy bridge class: which
# property names its `__js_get__` answers and which method names its
# `__js_call__` routes. Both are `case` dispatches over string literals, so the
# names can be read off the source AST without instantiating anything — which
# matters for an audit that has to cover interfaces Dommy cannot construct
# (and for reflected IDL attributes, which come from a class-level registry
# rather than a `when` arm at all).
#
# Uses RubyVM::AbstractSyntaxTree, so it is MRI-only; callers guard with
# `JsSurface.available?`.
module JsSurface
  AST = defined?(RubyVM::AbstractSyntaxTree) ? RubyVM::AbstractSyntaxTree : nil

  @file_ast = {}

  module_function

  def available?
    !AST.nil? && RUBY_ENGINE == "ruby"
  end

  def file_ast(path)
    @file_ast ||= {}
    @file_ast[path] ||= AST.parse_file(path)
  end

  # The string literals of the outer `case <first param>` dispatch in the
  # class's OWN definition of `method_name`. [] when the class does not define
  # it, or defines it function-style with no such dispatch. Non-string `when`
  # arms (an Integer index test, a Regexp) are skipped: they describe dynamic
  # properties, which `dynamic_dispatch?` reports separately.
  def own_when_strings(klass, method_name)
    unbound = own_instance_method(klass, method_name)
    return [] unless unbound

    node = dispatch_node(klass, unbound, method_name)
    node ? when_strings(node) : []
  end

  # Every JS-readable property name of `klass`, unioned across its ancestry:
  # the `__js_get__` dispatch arms of each ancestor that defines one, plus the
  # reflected IDL attributes declared with `reflect_string` / `reflect_boolean`
  # (which are answered by a shared registry lookup, not by a `when` arm).
  def js_properties(klass)
    names = ancestor_classes(klass).flat_map { |k| own_when_strings(k, :__js_get__) }
    if klass.respond_to?(:reflected_property_map)
      names += klass.reflected_property_map.keys.map(&:to_s)
    end
    names.uniq
  end

  # Every JS-callable method name of `klass`. `js_methods` records a class's OWN
  # names in JS_METHOD_NAMES; the union across the ancestry is what the host
  # exposes (see Bridge::Methods).
  def js_operations(klass)
    ancestor_classes(klass).flat_map do |k|
      k.const_defined?(:JS_METHOD_NAMES, false) ? k.const_get(:JS_METHOD_NAMES, false).map(&:to_s) : []
    end.uniq
  end

  # The Dommy classes and modules in `klass`'s ancestry, nearest first. Foreign
  # ancestors (Object, Kernel, StandardError) carry no bridge surface.
  def ancestor_classes(klass)
    klass.ancestors.select { |a| a.is_a?(Module) && a.name&.start_with?("Dommy") }
  end

  def own_instance_method(klass, method_name)
    return nil unless klass.is_a?(Module)

    unbound = begin
      klass.instance_method(method_name)
    rescue NameError
      return nil
    end
    unbound.owner.equal?(klass) ? unbound : nil
  end

  def dispatch_node(klass, unbound, method_name)
    file, line = unbound.source_location
    return nil unless file && File.exist?(file)

    defn = find_defn(file_ast(file), line, method_name)
    return nil unless defn

    param = unbound.parameters.first&.last
    return nil unless param

    find_method_case(defn, param)
  rescue StandardError
    nil
  end

  def find_defn(node, line, name)
    return node if node.type == :DEFN && node.children[0] == name && node.first_lineno == line

    node.children.each do |c|
      next unless c.is_a?(AST::Node)

      found = find_defn(c, line, name)
      return found if found
    end
    nil
  end

  # First `case` whose subject is the dispatch parameter (skips nested `case`s
  # on other variables, which live inside `when` bodies).
  def find_method_case(node, param)
    return nil unless node.is_a?(AST::Node)

    if node.type == :CASE
      subj = node.children[0]
      if subj.is_a?(AST::Node) && %i[LVAR DVAR].include?(subj.type) && subj.children[0] == param
        return node
      end
    end
    node.children.each do |c|
      next unless c.is_a?(AST::Node)

      found = find_method_case(c, param)
      return found if found
    end
    nil
  end

  # Walks only the dispatch case's direct `when` clauses (never descends into
  # arm bodies, so nested `case`s are not collected). Non-string conditions (an
  # Integer index test, a Regexp) name dynamic properties the arm list cannot
  # enumerate, and are skipped.
  def when_strings(case_node)
    out = []
    clause = case_node.children[1]
    while clause.is_a?(AST::Node) && clause.type == :WHEN
      conds = clause.children[0]
      nodes =
        if conds.is_a?(AST::Node) && %i[LIST ARRAY].include?(conds.type)
          conds.children.compact
        else
          [conds]
        end
      nodes.each { |cn| out << cn.children[0] if cn.is_a?(AST::Node) && cn.type == :STR }
      clause = clause.children[2]
    end
    out
  end
end
