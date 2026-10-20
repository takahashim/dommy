# frozen_string_literal: true

module Dommy
  module Encodings
    # HTML's "prescan a byte stream to determine its encoding" over the first
    # 1024 bytes: a walk over the bytes that skips comments and other tags as
    # the tokenizer would, and reads each `<meta>`'s attributes (quoted values
    # included) for a `charset`, or an `http-equiv="content-type"` with a
    # `content` naming one. Running out of bytes ends it with what a leading
    # `<?xml … encoding="…"?>` declares, if anything.
    #
    # Spec: https://html.spec.whatwg.org/#prescan-a-byte-stream-to-determine-its-encoding
    class Prescan
      LIMIT = 1024
      # ASCII whitespace, as bytes: TAB, LF, FF, CR, SPACE.
      SPACE = [0x09, 0x0A, 0x0C, 0x0D, 0x20].freeze
      SPACE_OR_SLASH = (SPACE + [0x2F]).freeze
      SPACE_OR_GT = (SPACE + [0x3E]).freeze
      private_constant :LIMIT, :SPACE, :SPACE_OR_SLASH, :SPACE_OR_GT

      def self.call(source) = new(source.to_s.b.byteslice(0, LIMIT)).run

      def initialize(bytes)
        @bytes = bytes
        @position = 0
      end

      def run
        utf16 = utf16_xml_declaration
        return utf16 if utf16

        catch(:end) do
          # Only a `<` starts anything; every other byte is passed over.
          while (@position = @bytes.index("<", @position))
            found =
              if starts_with?("<!--") then skip_comment
              elsif meta_tag? then meta
              elsif tag? then skip_tag
              elsif starts_with?("<!") || starts_with?("</") || starts_with?("<?") then skip_to(0x3E)
              end
            return found if found.is_a?(String)

            @position += 1
          end
        end
        xml_encoding
      end

      private

      # "Prescan for UTF-16 XML declarations": `<?x` in UTF-16 is UTF-16.
      def utf16_xml_declaration
        return "UTF-16LE" if @bytes.start_with?("<\0?\0x\0".b)

        "UTF-16BE" if @bytes.start_with?("\0<\0?\0x".b)
      end

      def byte
        @bytes.getbyte(@position) || throw(:end)
      end

      def starts_with?(text) = @bytes.byteslice(@position, text.bytesize) == text

      def letter?(value) = value && ((0x41..0x5A).cover?(value) || (0x61..0x7A).cover?(value))

      # `<meta` (ASCII case-insensitive) followed by whitespace or `/`.
      def meta_tag?
        @bytes.byteslice(@position, 5)&.casecmp?("<meta") && SPACE_OR_SLASH.include?(@bytes.getbyte(@position + 5))
      end

      # `<` or `</` followed by an ASCII letter.
      def tag?
        return false unless @bytes.getbyte(@position) == 0x3C

        letter?(@bytes.getbyte(@position + 1)) || (@bytes.getbyte(@position + 1) == 0x2F && letter?(@bytes.getbyte(@position + 2)))
      end

      # To the first `>` preceded by two `-` after the `<`; those may be the
      # `<!--`'s own, so `<!-->` and `<!--->` are closed comments.
      def skip_comment
        index = @bytes.index("-->".b, @position + 2) || throw(:end)
        @position = index + 2
      end

      def skip_to(value)
        index = @bytes.index(value.chr, @position + 1) || throw(:end)
        @position = index
      end

      # A tag that is not a `<meta>`: past its name, then its attributes, so a
      # `>` inside a quoted value does not end it.
      def skip_tag
        @position += 1
        @position += 1 until SPACE_OR_GT.include?(byte)
        nil while attribute
      end

      # The `<meta>` steps: its encoding when it declares one, else nil.
      def meta
        @position += 5
        names = []
        got_pragma = false
        need_pragma = nil
        charset = nil
        while (name, value = attribute)
          next if names.include?(name)

          names << name
          case name
          when "http-equiv"
            got_pragma = true if value == "content-type"
          when "content"
            encoding = encoding_from_content(value)
            if encoding && charset.nil?
              charset = encoding
              need_pragma = true
            end
          when "charset"
            charset = Encodings.get(value) || false
            need_pragma = false
          end
        end
        return nil if need_pragma.nil? || (need_pragma && !got_pragma) || !charset
        return "UTF-8" if charset.start_with?("UTF-16")

        charset == "x-user-defined" ? "windows-1252" : charset
      end

      # "Get an attribute": the next attribute's name and value (ASCII
      # lowercased, as bytes), or nil at the tag's `>`.
      def attribute
        @position += 1 while SPACE_OR_SLASH.include?(byte)
        return nil if byte == 0x3E

        name = +"".b
        value = +"".b
        loop do
          current = byte
          if current == 0x3D && !name.empty?
            @position += 1
            break
          elsif SPACE.include?(current)
            @position += 1 while SPACE.include?(byte)
            return [name, value] unless byte == 0x3D

            @position += 1
            break
          elsif current == 0x2F || current == 0x3E
            return [name, value]
          end
          name << lower(current)
          @position += 1
        end

        @position += 1 while SPACE.include?(byte)
        current = byte
        if current == 0x22 || current == 0x27
          loop do
            @position += 1
            if byte == current
              @position += 1
              return [name, value]
            end
            value << lower(byte)
          end
        end
        return [name, value] if current == 0x3E

        loop do
          current = byte
          return [name, value] if SPACE.include?(current) || current == 0x3E

          value << lower(current)
          @position += 1
        end
      end

      def lower(value) = (0x41..0x5A).cover?(value) ? value + 0x20 : value

      # HTML's "extracting a character encoding from a meta element", for a
      # `content` attribute's value: the encoding its `charset=` names, or nil.
      #
      # Spec: https://html.spec.whatwg.org/#algorithm-for-extracting-a-character-encoding-from-a-meta-element
      def encoding_from_content(content)
        position = 0
        loop do
          index = content.index(/charset/i, position) or return nil
          position = index + 7
          position += 1 while SPACE.include?(content.getbyte(position))
          next unless content.getbyte(position) == 0x3D

          position += 1
          position += 1 while SPACE.include?(content.getbyte(position))
          first = content.getbyte(position) or return nil
          if first == 0x22 || first == 0x27
            close = content.index(first.chr, position + 1) or return nil
            return Encodings.get(content.byteslice(position + 1...close))
          end
          return Encodings.get(content.byteslice(position..)[/\A[^\t\n\f\r ;]*/n])
        end
      end

      # "Get an XML encoding": the encoding a leading `<?xml` declaration's
      # `encoding="…"` (before its `>`, quoted, with no byte at or below 0x20)
      # names, with UTF-16 read as UTF-8, or nil.
      def xml_encoding
        return nil unless @bytes.start_with?("<?xml")

        finish = @bytes.index(">") or return nil
        position = @bytes.index("encoding")
        return nil if position.nil? || position >= finish

        position = skip_controls(position + 8)
        return nil unless @bytes.getbyte(position) == 0x3D

        position = skip_controls(position + 1)
        quote = @bytes.getbyte(position)
        return nil unless quote == 0x22 || quote == 0x27

        close = @bytes.index(quote.chr, position + 1) or return nil
        label = @bytes.byteslice(position + 1...close)
        return nil if label.each_byte.any? { |value| value <= 0x20 }

        name = Encodings.get(label)
        name&.start_with?("UTF-16") ? "UTF-8" : name
      end

      def skip_controls(position)
        position += 1 while (value = @bytes.getbyte(position)) && value <= 0x20
        position
      end
    end
  end
end
