# frozen_string_literal: true

require_relative "test_helper"

# FormData's "create an entry" (XHR): a Blob that is not a File becomes a
# File named "blob", and a filename given to append or set names the File —
# so a file entry is always a File, with its bytes and type.
class TestFormDataEntries < Minitest::Test
  def entry(*args)
    data = Dommy::FormData.new
    data.append("k", *args)
    data.get("k")
  end

  def test_a_blob_becomes_a_file_named_blob
    file = entry(Dommy::Blob.new(["x"], { "type" => "text/plain" }))
    assert_instance_of Dommy::File, file
    assert_equal ["blob", "text/plain", "x"], [file.name, file.type, file.__dommy_bytes__]
  end

  def test_a_filename_names_the_file
    assert_equal "named.bin", entry(Dommy::Blob.new(["z"]), "named.bin").name
    assert_equal "renamed.txt", entry(Dommy::File.new(["y"], "orig.txt"), "renamed.txt").name
    original = Dommy::File.new(["y"], "orig.txt")
    assert_same original, entry(original)
  end

  def test_a_blob_is_sent_as_a_file_named_blob
    data = Dommy::FormData.new
    data.append("k", Dommy::Blob.new(["x"]))
    body, = Dommy::Response.multipart_body(data)
    assert_includes body, 'filename="blob"'
  end
end
