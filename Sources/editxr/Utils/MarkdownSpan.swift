import Foundation

enum SpanKind {
    case bold
    case italic
    case code
    case heading1
    case heading2
    case heading3
}

struct MarkdownSpan {
    let kind: SpanKind
    let rawStart: Int       // start index in raw text (includes markers)
    let rawEnd: Int         // end index in raw text (includes markers)
    let contentStart: Int   // start of actual content (excludes markers)
    let contentEnd: Int     // end of actual content (excludes markers)
    let content: String     // the text without markers
    
    var rawRange: Range<Int> { rawStart..<rawEnd }
    var contentRange: Range<Int> { contentStart..<contentEnd }
    var markerLength: Int {
        switch kind {
        case .bold: return 2
        case .italic: return 1
        case .code: return 1
        case .heading1: return 2
        case .heading2: return 3
        case .heading3: return 4
        }
    }
}

struct MarkdownLineParser {
    
    static func parse(_ line: String) -> [MarkdownSpan] {
        if let headingSpan = parseHeading(line) {
            return [headingSpan]
        }
        
        var spans: [MarkdownSpan] = []
        let chars = Array(line)
        var i = 0
        
        while i < chars.count {
            if i + 1 < chars.count && chars[i] == "*" && chars[i + 1] == "*" {
                if let span = parseBold(chars: chars, startIndex: i) {
                    spans.append(span)
                    i = span.rawEnd
                    continue
                }
            }
            
            if chars[i] == "*" && (i + 1 >= chars.count || chars[i + 1] != "*") {
                if let span = parseItalic(chars: chars, startIndex: i) {
                    spans.append(span)
                    i = span.rawEnd
                    continue
                }
            }
            
            if chars[i] == "`" {
                if let span = parseCode(chars: chars, startIndex: i) {
                    spans.append(span)
                    i = span.rawEnd
                    continue
                }
            }
            
            i += 1
        }
        
        return spans
    }
    
    static func isCodeBlockDelimiter(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.hasPrefix("```")
    }
    
    private static func parseHeading(_ line: String) -> MarkdownSpan? {
        let chars = Array(line)
        guard !chars.isEmpty && chars[0] == "#" else { return nil }
        
        var level = 0
        while level < chars.count && level < 3 && chars[level] == "#" {
            level += 1
        }
        
        guard level < chars.count && chars[level] == " " else { return nil }
        
        let markerLength = level + 1
        let content = String(chars[markerLength...])
        let kind: SpanKind = level == 1 ? .heading1 : (level == 2 ? .heading2 : .heading3)
        
        return MarkdownSpan(
            kind: kind,
            rawStart: 0,
            rawEnd: chars.count,
            contentStart: markerLength,
            contentEnd: chars.count,
            content: content
        )
    }
    private static func parseBold(chars: [Character], startIndex: Int) -> MarkdownSpan? {
        guard startIndex + 2 < chars.count else { return nil }
        
        // Find closing **
        var i = startIndex + 2
        while i + 1 < chars.count {
            if chars[i] == "*" && chars[i + 1] == "*" {
                let contentStart = startIndex + 2
                let contentEnd = i
                guard contentEnd > contentStart else { return nil }
                
                let content = String(chars[contentStart..<contentEnd])
                return MarkdownSpan(
                    kind: .bold,
                    rawStart: startIndex,
                    rawEnd: i + 2,
                    contentStart: contentStart,
                    contentEnd: contentEnd,
                    content: content
                )
            }
            i += 1
        }
        return nil
    }
    
    /// Parse italic: *text*
    private static func parseItalic(chars: [Character], startIndex: Int) -> MarkdownSpan? {
        guard startIndex + 1 < chars.count else { return nil }
        
        // Find closing * (but not **)
        var i = startIndex + 1
        while i < chars.count {
            if chars[i] == "*" && (i + 1 >= chars.count || chars[i + 1] != "*") {
                let contentStart = startIndex + 1
                let contentEnd = i
                guard contentEnd > contentStart else { return nil }
                
                let content = String(chars[contentStart..<contentEnd])
                return MarkdownSpan(
                    kind: .italic,
                    rawStart: startIndex,
                    rawEnd: i + 1,
                    contentStart: contentStart,
                    contentEnd: contentEnd,
                    content: content
                )
            }
            i += 1
        }
        return nil
    }
    
    /// Parse code: `text`
    private static func parseCode(chars: [Character], startIndex: Int) -> MarkdownSpan? {
        guard startIndex + 1 < chars.count else { return nil }
        
        // Find closing `
        var i = startIndex + 1
        while i < chars.count {
            if chars[i] == "`" {
                let contentStart = startIndex + 1
                let contentEnd = i
                guard contentEnd > contentStart else { return nil }
                
                let content = String(chars[contentStart..<contentEnd])
                return MarkdownSpan(
                    kind: .code,
                    rawStart: startIndex,
                    rawEnd: i + 1,
                    contentStart: contentStart,
                    contentEnd: contentEnd,
                    content: content
                )
            }
            i += 1
        }
        return nil
    }
    
    /// Check if cursor (raw column) is inside any span
    static func spanContainingCursor(column: Int, spans: [MarkdownSpan]) -> MarkdownSpan? {
        for span in spans {
            if column >= span.rawStart && column < span.rawEnd {
                return span
            }
        }
        return nil
    }
    
    /// Convert raw column to visual column (collapsed view)
    static func rawToVisual(column: Int, spans: [MarkdownSpan]) -> Int {
        var offset = 0
        
        for span in spans {
            if column <= span.rawStart {
                // Cursor is before this span
                break
            } else if column >= span.rawEnd {
                // Cursor is after this span - subtract both markers
                offset += span.markerLength * 2
            } else if column >= span.contentStart && column < span.contentEnd {
                // Cursor is inside content - subtract opening marker only
                offset += span.markerLength
            } else if column < span.contentStart {
                // Cursor is in opening marker
                offset += column - span.rawStart
            } else {
                // Cursor is in closing marker
                offset += span.markerLength + (column - span.contentEnd)
            }
        }
        
        return column - offset
    }
    
    /// Convert visual column to raw column (for navigation)
    static func visualToRaw(column: Int, spans: [MarkdownSpan]) -> Int {
        var rawCol = 0
        var visualCol = 0
        
        // Sort spans by position
        let sortedSpans = spans.sorted { $0.rawStart < $1.rawStart }
        var spanIndex = 0
        
        while visualCol < column {
            // Check if we're entering a span
            if spanIndex < sortedSpans.count && rawCol == sortedSpans[spanIndex].rawStart {
                let span = sortedSpans[spanIndex]
                let contentLength = span.contentEnd - span.contentStart
                let visualRemaining = column - visualCol
                
                if visualRemaining <= contentLength {
                    // Target is inside this span's content
                    return span.contentStart + visualRemaining
                } else {
                    // Skip entire span
                    visualCol += contentLength
                    rawCol = span.rawEnd
                    spanIndex += 1
                }
            } else {
                rawCol += 1
                visualCol += 1
            }
        }
        
        return rawCol
    }
}
