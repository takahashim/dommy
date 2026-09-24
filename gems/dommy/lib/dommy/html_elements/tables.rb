# frozen_string_literal: true

module Dommy
  # The table and the elements that only appear inside one.
  #
  # One of the HTML element groups; html_elements.rb lists them all.
  # `<td>` / `<th>` — single table cell. `cellIndex` is the
  # position within the parent row's cells collection.
  class HTMLTableCellElement < HTMLElement
    reflect_string :headers, :scope, :abbr
    def cell_index
      # cellIndex is the position in the DIRECT parent row's cells — -1 unless the
      # cell's immediate parent is a tr (a cell nested in a non-tr is not indexed).
      row = parent_element
      return -1 unless row.is_a?(HTMLTableRowElement)

      row.cells.find_index { |c| c.__dommy_backend_node__ == @__node__ } || -1
    end

    reflect_ulong col_span: { attr: "colspan", default: 1, range: 1..1000 },
                  row_span: { attr: "rowspan", default: 1, range: 0..65_534 }

    # `scope` / `abbr` are only meaningful on `<th>`, but the IDL
    # exposes them on the cell element either way.

    js_accessor :col_span, :row_span
    js_readable :cell_index

  end

  # `<tr>` — table row. `cells` are direct `<td>`/`<th>` children.
  # `rowIndex` walks the enclosing table; `sectionRowIndex` walks
  # the enclosing thead/tbody/tfoot.

  # `<tr>` — table row. `cells` are direct `<td>`/`<th>` children.
  # `rowIndex` walks the enclosing table; `sectionRowIndex` walks
  # the enclosing thead/tbody/tfoot.
  class HTMLTableRowElement < HTMLElement
    HTML_NAMESPACE = Internal::Namespaces::HTML

    # Own __js_call__ methods, on top of Element's.
    def cells
      el = self
      @cells ||= HTMLCollection.new do
        el.__dommy_backend_node__.element_children
          .select { |n| %w[td th].include?(n.name) && el.__html_ns_node__(n) }
          .map { |n| el.document.wrap_node(n) }.compact
      end
    end

    def row_index
      table = closest("table")
      # Only an HTML <table> exposes a rows collection; a foreign (namespaced)
      # <table> ancestor doesn't make this row a table row.
      return -1 unless table.is_a?(HTMLTableElement)

      table.rows.find_index { |r| r.__dommy_backend_node__ == @__node__ } || -1
    end

    def section_row_index
      parent = @__node__.parent
      return -1 unless parent && parent.element? && __html_ns_node__(parent) &&
                       %w[table thead tbody tfoot].include?(parent.name)

      parent.element_children
        .select { |n| n.name == "tr" && __html_ns_node__(n) }
        .find_index { |n| n == @__node__ } || -1
    end

    # `insertCell(index)` — adds a `<td>` at the given index (defaults to end).
    # index < −1 or > cells.length throws IndexSizeError. Returns the new cell.
    def insert_cell(index = -1)
      list = cells.to_a
      i = index.nil? ? -1 : index.to_i
      raise DOMException::IndexSizeError, "insertCell index #{i} out of range" if i < -1 || i > list.size

      cell = @document.create_element("td")
      if i == -1 || i == list.size
        append_child(cell)
      else
        insert_before(cell, list[i])
      end

      cell
    end

    def delete_cell(index)
      list = cells.to_a
      i = index.to_i
      raise DOMException::IndexSizeError, "deleteCell index #{i} out of range" if i < -1 || i >= list.size

      target = i == -1 ? list.last : list[i]
      target&.remove
      nil
    end

    def __html_ns_node__(node)
      el = @document.wrap_node(node)
      !el.respond_to?(:namespace_uri) || el.namespace_uri == HTML_NAMESPACE
    end

    js_readable :cells, :row_index, :section_row_index

    js_methods %w[insertCell deleteCell]
    def __js_call__(method, args)
      case method
      when "insertCell"
        insert_cell(args[0] || -1)
      when "deleteCell"
        delete_cell(args[0])
      else
        super
      end
    end
  end

  # `<thead>` / `<tbody>` / `<tfoot>` — share section-level row
  # collection + insertRow / deleteRow.

  # `<thead>` / `<tbody>` / `<tfoot>` — share section-level row
  # collection + insertRow / deleteRow.
  class HTMLTableSectionElement < HTMLElement
    # Own __js_call__ methods, on top of Element's.
    HTML_NAMESPACE = Internal::Namespaces::HTML

    def rows
      el = self
      @rows ||= HTMLCollection.new do
        el.__dommy_backend_node__.element_children
          .select { |n| n.name == "tr" && el.__html_ns_node__(n) }
          .map { |n| el.document.wrap_node(n) }.compact
      end
    end

    def insert_row(index = -1)
      list = rows.to_a
      i = index.nil? ? -1 : index.to_i
      raise DOMException::IndexSizeError, "insertRow index #{i} out of range" if i < -1 || i > list.size

      tr = @document.create_element("tr")
      if i == -1 || i == list.size
        append_child(tr)
      else
        insert_before(tr, list[i])
      end

      tr
    end

    def delete_row(index)
      list = rows.to_a
      i = index.to_i
      raise DOMException::IndexSizeError, "deleteRow index #{i} out of range" if i < -1 || i >= list.size

      target = i == -1 ? list.last : list[i]
      target&.remove
      nil
    end

    def __html_ns_node__(node)
      el = @document.wrap_node(node)
      !el.respond_to?(:namespace_uri) || el.namespace_uri == HTML_NAMESPACE
    end

    def __js_get__(key)
      key == "rows" ? rows : super
    end

    js_methods %w[insertRow deleteRow]
    def __js_call__(method, args)
      case method
      when "insertRow"
        insert_row(args[0] || -1)
      when "deleteRow"
        delete_row(args[0])
      else
        super
      end
    end
  end

  # `<caption>` — table caption, minimal subclass.

  # `<caption>` — table caption, minimal subclass.
  class HTMLTableCaptionElement < HTMLElement
  end

  # `<table>` — top-level table element. `rows` returns rows from
  # all sections (thead → tbody → tfoot); `tBodies` is a list of
  # tbody elements. `insertRow(-1)` appends to the last tbody (or
  # creates one); `deleteRow` works against the merged `rows` list.

  # `<table>` — top-level table element. `rows` returns rows from
  # all sections (thead → tbody → tfoot); `tBodies` is a list of
  # tbody elements. `insertRow(-1)` appends to the last tbody (or
  # creates one); `deleteRow` works against the merged `rows` list.
  class HTMLTableElement < HTMLElement
    HTML_NAMESPACE = Internal::Namespaces::HTML

    # Own __js_call__ methods, on top of Element's.
    def caption
      first_html_child("caption")
    end

    def caption=(new_caption)
      if !new_caption.nil? && !new_caption.is_a?(HTMLTableCaptionElement)
        raise Bridge::TypeError, "table.caption must be an HTMLTableCaptionElement or null"
      end

      delete_caption
      return if new_caption.nil?

      # Route through the validated insertion so a cycle (the caption already
      # containing this table) raises HierarchyRequestError and a caption from
      # another document is adopted, rather than corrupting the tree.
      insert_before(new_caption, first_child)
    end

    def t_head
      first_html_child("thead")
    end

    def t_foot
      first_html_child("tfoot")
    end

    def t_bodies
      el = self
      @t_bodies ||= HTMLCollection.new do
        el.__dommy_backend_node__.element_children
          .select { |n| n.name == "tbody" && el.__html_namespace_node__(n) }
          .map { |n| el.document.wrap_node(n) }.compact
      end
    end

    def rows
      el = self
      @rows ||= HTMLCollection.new do
        # Per spec: thead rows first, then the tr children of the table and of
        # tbody sections IN TREE ORDER (a direct <tr> and a <tbody>'s rows
        # interleave by document position), then tfoot rows.
        head_rows = []
        body_rows = []
        foot_rows = []
        el.__dommy_backend_node__.element_children.each do |n|
          next unless el.__html_namespace_node__(n)

          case n.name
          when "thead"
            el.__tr_children__(n).each { |c| head_rows << c }
          when "tfoot"
            el.__tr_children__(n).each { |c| foot_rows << c }
          when "tbody"
            el.__tr_children__(n).each { |c| body_rows << c }
          when "tr"
            body_rows << n
          end
        end
        (head_rows + body_rows + foot_rows).map { |n| el.document.wrap_node(n) }.compact
      end
    end

    # The HTML-namespaced <tr> element children of a section node.
    def __tr_children__(section)
      section.element_children.select { |n| n.name == "tr" && __html_namespace_node__(n) }
    end

    # The first HTML-namespaced element child with the given local name (a
    # same-name element in another namespace, e.g. SVG's <caption>, is skipped).
    def first_html_child(local)
      node = @__node__.element_children.find { |n| n.name == local && __html_namespace_node__(n) }
      node && @document.wrap_node(node)
    end

    # Whether a raw backend node is in the HTML namespace.
    def __html_namespace_node__(node)
      el = @document.wrap_node(node)
      !el.respond_to?(:namespace_uri) || el.namespace_uri == HTML_NAMESPACE
    end

    def create_caption
      existing = caption
      return existing if existing

      cap = @document.create_element("caption")
      first = @__node__.children.first
      first ? first.add_previous_sibling(cap.__dommy_backend_node__) : @__node__.add_child(cap.__dommy_backend_node__)
      cap
    end

    def delete_caption
      cap = caption
      cap&.remove
      nil
    end

    def create_t_head
      existing = t_head
      return existing if existing

      head = @document.create_element("thead")
      cap = caption
      if cap
        cap.__dommy_backend_node__.add_next_sibling(head.__dommy_backend_node__)
      else
        first = @__node__.children.first
        first ? first.add_previous_sibling(head.__dommy_backend_node__) : @__node__.add_child(head.__dommy_backend_node__)
      end

      head
    end

    def delete_t_head
      t_head&.remove
      nil
    end

    def create_t_foot
      existing = t_foot
      return existing if existing

      foot = @document.create_element("tfoot")
      @__node__.add_child(foot.__dommy_backend_node__)
      foot
    end

    def delete_t_foot
      t_foot&.remove
      nil
    end

    def create_t_body
      tb = @document.create_element("tbody")
      last_tbody = t_bodies.last
      if last_tbody
        last_tbody.__dommy_backend_node__.add_next_sibling(tb.__dommy_backend_node__)
      else
        @__node__.add_child(tb.__dommy_backend_node__)
      end

      tb
    end

    # `table.insertRow(index)` — inserts a `<tr>` at the merged
    # index. Per spec, if no `<tbody>` exists and the table is
    # empty, the row is inserted directly; otherwise it goes into
    # the last `<tbody>`.
    def insert_row(index = -1)
      list = rows.to_a
      raw = index.to_i
      raise DOMException::IndexSizeError, "row index #{raw} out of range" if raw < -1 || raw > list.size

      idx = raw == -1 ? list.size : raw

      tr = @document.create_element("tr")
      if idx == list.size
        target_section = t_bodies.last || create_t_body
        target_section.append_child(tr)
      else
        anchor = list[idx]
        section = anchor.__dommy_backend_node__.parent
        if section
          @document.__internal_ranges_will_insert__(section, anchor.__dommy_backend_node__, 1)
          anchor.__dommy_backend_node__.add_previous_sibling(tr.__dommy_backend_node__)
          @document.notify_child_list_mutation(target_node: section, added_nodes: [tr.__dommy_backend_node__], removed_nodes: [])
        end
      end

      tr
    end

    def delete_row(index)
      list = rows.to_a
      i = index.to_i
      raise DOMException::IndexSizeError, "deleteRow index #{i} out of range" if i < -1 || i >= list.size

      target = i == -1 ? list.last : list[i]
      target&.remove
      nil
    end

    # `table.tHead = x` / `table.tFoot = x`: x must be a matching section element
    # (or null). It replaces the existing one at the spec position.
    def t_head=(value)
      set_table_section("thead", value)
    end

    def t_foot=(value)
      set_table_section("tfoot", value)
    end

    def set_table_section(local, value)
      if value.nil?
        first_html_child(local)&.remove
        return
      end
      # A non-section value fails the WebIDL type check (TypeError); a section of
      # the wrong local name fails the spec's algorithm (HierarchyRequestError).
      unless value.is_a?(HTMLTableSectionElement)
        raise Bridge::TypeError, "table.#{local} must be an HTMLTableSectionElement or null"
      end
      unless value.tag_name.to_s.casecmp?(local)
        raise DOMException::HierarchyRequestError, "table.#{local} must be a <#{local}> element"
      end

      first_html_child(local)&.remove
      # A validated insertion (cycle → HierarchyRequestError, cross-document →
      # adopt). thead goes just after any caption; tfoot is appended last.
      if local == "thead"
        cap = caption
        insert_before(value, cap ? cap.next_sibling : first_child)
      else
        append_child(value)
      end
      value
    end

    js_accessor :caption, :t_head, :t_foot
    js_readable :t_bodies, :rows


    js_methods %w[
      insertRow deleteRow createCaption deleteCaption createTHead deleteTHead createTFoot
      deleteTFoot createTBody
    ]
    def __js_call__(method, args)
      case method
      when "insertRow"
        insert_row(args[0] || -1)
      when "deleteRow"
        delete_row(args[0])
        Bridge::UNDEFINED
      when "createCaption"
        create_caption
      when "deleteCaption"
        delete_caption
        Bridge::UNDEFINED
      when "createTHead"
        create_t_head
      when "deleteTHead"
        delete_t_head
        Bridge::UNDEFINED
      when "createTFoot"
        create_t_foot
      when "deleteTFoot"
        delete_t_foot
        Bridge::UNDEFINED
      when "createTBody"
        create_t_body
      else
        super
      end
    end
  end

  # `<audio>` / `<video>` shared base. The actual media engine is
  # absent in Dommy — getters return inert values, `play()` returns
  # a resolved Promise, and `pause()` flips `paused` back to true.

  # Element interfaces that are otherwise plain HTMLElement subclasses — their
  # own IDL adds little beyond the base, but they must be distinct types so
  # `createElement("col") instanceof HTMLTableColElement` (and cloneNode
  # identity) holds. `col`/`colgroup` share HTMLTableColElement per spec.
  class HTMLTableColElement < HTMLElement; end
end
