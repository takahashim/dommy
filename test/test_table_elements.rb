# frozen_string_literal: true

require_relative "test_helper"

class TestHTMLTableElement < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window(
      <<~HTML
        <table id="t">
          <caption>My caption</caption>
          <thead>
            <tr><th>Name</th><th>Age</th></tr>
          </thead>
          <tbody>
            <tr><td>Alice</td><td>30</td></tr>
            <tr><td>Bob</td><td>25</td></tr>
          </tbody>
          <tfoot>
            <tr><td colspan='2'>Total: 2</td></tr>
          </tfoot>
        </table>
      HTML
    )
    @doc = @win.document
    @table = @doc.get_element_by_id("t")
  end

  def test_class_dispatch
    assert_kind_of(Dommy::HTMLTableElement, @table)
  end

  def test_caption_accessor
    assert_kind_of(Dommy::HTMLTableCaptionElement, @table.caption)
    assert_equal("My caption", @table.caption.text_content)
  end

  def test_t_head_accessor
    head = @table.t_head
    assert_kind_of(Dommy::HTMLTableSectionElement, head)
    assert_equal("THEAD", head.tag_name)
  end

  def test_t_foot_accessor
    foot = @table.t_foot
    assert_kind_of(Dommy::HTMLTableSectionElement, foot)
    assert_equal("TFOOT", foot.tag_name)
  end

  def test_t_bodies_collection
    bodies = @table.t_bodies
    assert_equal(1, bodies.size)
    assert_equal("TBODY", bodies.first.tag_name)
  end

  def test_rows_merge_thead_tbody_tfoot
    rows = @table.rows
    # 1 header + 2 body + 1 footer
    assert_equal(4, rows.size)
    # First row should be the header row.
    assert_equal("TH", rows[0].cells[0].tag_name)
    assert_equal("TD", rows[1].cells[0].tag_name)
  end

  def test_insert_row_appends_to_last_tbody
    initial = @table.rows.size
    new_row = @table.insert_row
    assert_kind_of(Dommy::HTMLTableRowElement, new_row)
    # Inserted into the last tbody, which appears before tfoot.
    assert_equal(initial + 1, @table.rows.size)
  end

  def test_insert_row_at_index
    new_row = @table.insert_row(1)
    new_row.insert_cell.text_content = "Inserted"
    # Row 0 = thead's tr, Row 1 should now be new_row.
    assert_same(new_row.__node__, @table.rows[1].__node__)
  end

  def test_delete_row_by_index
    initial = @table.rows.size
    @table.delete_row(1)
    assert_equal(initial - 1, @table.rows.size)
  end

  def test_create_caption_returns_existing_if_present
    cap = @table.create_caption
    assert_same(@table.caption.__node__, cap.__node__)
  end

  def test_create_caption_when_absent
    @table.delete_caption
    assert_nil(@table.caption)
    cap = @table.create_caption
    refute_nil(@table.caption)
    assert_same(cap.__node__, @table.caption.__node__)
  end

  def test_create_t_head_returns_existing
    head = @table.create_t_head
    assert_same(@table.t_head.__node__, head.__node__)
  end

  def test_create_t_head_when_absent
    @table.delete_t_head
    assert_nil(@table.t_head)
    @table.create_t_head
    refute_nil(@table.t_head)
  end

  def test_create_t_body_appends
    initial = @table.t_bodies.size
    @table.create_t_body
    assert_equal(initial + 1, @table.t_bodies.size)
  end
end

class TestHTMLTableSectionElement < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window(
      <<~HTML
        <table>
          <tbody id='b'>
            <tr><td>A</td></tr>
            <tr><td>B</td></tr>
          </tbody>
        </table>
      HTML
    )
    @body = @win.document.get_element_by_id("b")
  end

  def test_class_dispatch
    assert_kind_of(Dommy::HTMLTableSectionElement, @body)
  end

  def test_rows_returns_only_tr_children
    assert_equal(2, @body.rows.size)
    @body.rows.each { |r| assert_equal("TR", r.tag_name) }
  end

  def test_insert_row_at_end
    @body.insert_row
    assert_equal(3, @body.rows.size)
  end

  def test_insert_row_at_position
    new_row = @body.insert_row(1)
    assert_same(new_row.__node__, @body.rows[1].__node__)
  end

  def test_delete_row
    @body.delete_row(0)
    assert_equal(1, @body.rows.size)
  end
end

class TestHTMLTableRowElement < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window(
      <<~HTML
        <table>
          <thead><tr><th>H1</th><th>H2</th></tr></thead>
          <tbody>
            <tr id='r1'><td>A</td><td>B</td><td>C</td></tr>
            <tr id='r2'><td>D</td><td>E</td></tr>
          </tbody>
        </table>
      HTML
    )
    @r1 = @win.document.get_element_by_id("r1")
    @r2 = @win.document.get_element_by_id("r2")
  end

  def test_class_dispatch
    assert_kind_of(Dommy::HTMLTableRowElement, @r1)
  end

  def test_cells_returns_td_th_children
    assert_equal(3, @r1.cells.size)
    @r1.cells.each { |c| assert_includes(["TD", "TH"], c.tag_name) }
  end

  def test_row_index_within_table
    # Header row = 0, r1 = 1, r2 = 2
    assert_equal(1, @r1.row_index)
    assert_equal(2, @r2.row_index)
  end

  def test_section_row_index_within_tbody
    # r1 is the first tr in its tbody
    assert_equal(0, @r1.section_row_index)
    assert_equal(1, @r2.section_row_index)
  end

  def test_insert_cell_appends_td
    cell = @r1.insert_cell
    assert_kind_of(Dommy::HTMLTableCellElement, cell)
    assert_equal("TD", cell.tag_name)
    assert_equal(4, @r1.cells.size)
  end

  def test_insert_cell_at_position
    cell = @r1.insert_cell(1)
    assert_same(cell.__node__, @r1.cells[1].__node__)
  end

  def test_delete_cell
    @r1.delete_cell(0)
    assert_equal(2, @r1.cells.size)
  end
end

class TestHTMLTableCellElement < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window(
      <<~HTML
        <table>
          <tr id='r'>
            <th id='th' scope="col" abbr="N">Name</th>
            <td id='c0' colspan="2" rowspan="3" headers="th">Alice</td>
            <td id='c1'>30</td>
          </tr>
        </table>
      HTML
    )
    @doc = @win.document
    @th = @doc.get_element_by_id("th")
    @c0 = @doc.get_element_by_id("c0")
    @c1 = @doc.get_element_by_id("c1")
  end

  def test_class_dispatch
    assert_kind_of(Dommy::HTMLTableCellElement, @th)
    assert_kind_of(Dommy::HTMLTableCellElement, @c0)
  end

  def test_cell_index
    assert_equal(0, @th.cell_index)
    assert_equal(1, @c0.cell_index)
    assert_equal(2, @c1.cell_index)
  end

  def test_col_span_default_one
    assert_equal(1, @c1.col_span)
  end

  def test_col_span_from_attribute
    assert_equal(2, @c0.col_span)
  end

  def test_col_span_setter
    @c1.col_span = 3
    assert_equal("3", @c1.get_attribute("colspan"))
    assert_equal(3, @c1.col_span)
  end

  def test_row_span
    assert_equal(3, @c0.row_span)
  end

  def test_headers
    assert_equal("th", @c0.headers)
  end

  def test_scope_and_abbr_on_th
    assert_equal("col", @th.scope)
    assert_equal("N", @th.abbr)
  end

  def test_js_get_routes
    assert_equal(2, @c0.__js_get__("colSpan"))
    assert_equal(1, @c0.__js_get__("cellIndex"))
  end
end

class TestTableIntegration < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window("<table id='t'></table>")
    @table = @win.document.get_element_by_id("t")
  end

  def test_build_table_from_scratch
    @table.create_caption.text_content = "Built"
    head = @table.create_t_head
    head_row = head.insert_row
    head_row.insert_cell.text_content = "Col1"
    head_row.insert_cell.text_content = "Col2"

    body_row = @table.insert_row
    body_row.insert_cell.text_content = "A"
    body_row.insert_cell.text_content = "B"

    assert_equal("Built", @table.caption.text_content)
    # header row + body row
    assert_equal(2, @table.rows.size)
    assert_equal(2, @table.rows[0].cells.size)
    assert_equal("A", @table.rows[1].cells[0].text_content)
  end
end
