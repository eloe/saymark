// Pinned, pure-Swift Unicode 15.1.0 normalization, default case folding, and
// UAX #29 word-boundary primitives. Generated data is in
// Unicode15_1Generated.swift; this file deliberately does not import Foundation
// or call host ICU so correction behavior cannot vary by macOS release.

internal enum Unicode15_1 {
    static let version = Unicode15_1Generated.version

    static func nfkc(_ input: String) -> String {
        let decomposed = canonicalOrder(recursiveDecompose(input.unicodeScalars.map(\.value)))
        return string(compose(decomposed))
    }

    static func defaultCaseFold(_ input: String) -> String {
        var output: [UInt32] = []
        output.reserveCapacity(input.unicodeScalars.count)
        for scalar in input.unicodeScalars.map(\.value) {
            if let mapping = caseFoldMapping(scalar) {
                output.append(contentsOf: mapping)
            } else {
                output.append(scalar)
            }
        }
        return string(output)
    }

    static func nfkcCaseFold(_ input: String) -> String {
        // Saymark's match-key contract is NFKC followed by default case folding;
        // this intentionally is not the distinct Unicode NFKC_Casefold property.
        defaultCaseFold(nfkc(input))
    }

    static func wordBoundaries(in input: String) -> [Bool] {
        let scalars = input.unicodeScalars.map(\.value)
        guard !scalars.isEmpty else { return [true] }

        // UAX #29 WB4: Extend, Format, and ZWJ are ignored for the purpose of
        // determining boundaries, except where a rule explicitly consumes ZWJ.
        // We project decisions back to scalar positions so callers never need
        // host grapheme segmentation.
        let properties = scalars.map(wordBreakProperty)
        var result = Array(repeating: true, count: scalars.count + 1)
        result[0] = true
        result[scalars.count] = true

        for boundary in 1..<scalars.count {
            result[boundary] = shouldBreak(
                leftIndex: boundary - 1,
                rightIndex: boundary,
                scalars: scalars,
                properties: properties
            )
        }
        return result
    }

    static func wordBreakProperty(_ scalar: UInt32) -> WordBreakProperty {
        let ranges = Unicode15_1Generated.wordBreakRanges
        var low = 0
        var high = ranges.count / 3
        while low < high {
            let middle = (low + high) / 2
            let start = ranges[middle * 3]
            let end = ranges[middle * 3 + 1]
            if scalar < start {
                high = middle
            } else if scalar > end {
                low = middle + 1
            } else {
                return WordBreakProperty(rawValue: ranges[middle * 3 + 2]) ?? .other
            }
        }
        return .other
    }
}

internal enum WordBreakProperty: UInt32 {
    case other = 0
    case cr = 1
    case lf = 2
    case newline = 3
    case extend = 4
    case zwj = 5
    case regionalIndicator = 6
    case format = 7
    case katakana = 8
    case hebrewLetter = 9
    case aLetter = 10
    case singleQuote = 11
    case doubleQuote = 12
    case midNumLet = 13
    case midLetter = 14
    case midNum = 15
    case numeric = 16
    case extendNumLet = 17
    case wSegSpace = 18
    case extendedPictographic = 19
}

private extension Unicode15_1 {
    static func recursiveDecompose(_ input: [UInt32]) -> [UInt32] {
        var output: [UInt32] = []
        output.reserveCapacity(input.count)
        for scalar in input {
            if let hangul = decomposeHangul(scalar) {
                output.append(contentsOf: recursiveDecompose(hangul))
            } else if let mapping = decompositionMapping(scalar) {
                output.append(contentsOf: recursiveDecompose(mapping))
            } else {
                output.append(scalar)
            }
        }
        return output
    }

    static func canonicalOrder(_ input: [UInt32]) -> [UInt32] {
        var output: [UInt32] = []
        output.reserveCapacity(input.count)
        var segmentStart = 0
        for scalar in input {
            let currentClass = combiningClass(scalar)
            if currentClass == 0 {
                segmentStart = output.count
                output.append(scalar)
                continue
            }
            var position = output.count
            while position > segmentStart + 1 && combiningClass(output[position - 1]) > currentClass {
                position -= 1
            }
            output.insert(scalar, at: position)
        }
        return output
    }

    static func compose(_ input: [UInt32]) -> [UInt32] {
        guard !input.isEmpty else { return [] }
        var output: [UInt32] = [input[0]]
        var starterIndex = 0
        var lastClass: UInt32 = combiningClass(input[0])
        for scalar in input.dropFirst() {
            let currentClass = combiningClass(scalar)
            let starter = output[starterIndex]
            if let composed = composeHangul(starter, scalar) ?? composition(starter, scalar),
               lastClass == 0 || lastClass < currentClass {
                output[starterIndex] = composed
            } else {
                output.append(scalar)
                if currentClass == 0 { starterIndex = output.count - 1 }
                lastClass = currentClass
            }
        }
        return output
    }

    static func decomposeHangul(_ scalar: UInt32) -> [UInt32]? {
        let sBase: UInt32 = 0xAC00, lBase: UInt32 = 0x1100, vBase: UInt32 = 0x1161, tBase: UInt32 = 0x11A7
        let vCount: UInt32 = 21, tCount: UInt32 = 28, nCount = vCount * tCount, sCount: UInt32 = 19 * nCount
        guard scalar >= sBase && scalar < sBase + sCount else { return nil }
        let index = scalar - sBase
        let l = lBase + index / nCount
        let v = vBase + (index % nCount) / tCount
        let t = tBase + index % tCount
        return t == tBase ? [l, v] : [l, v, t]
    }

    static func composeHangul(_ first: UInt32, _ second: UInt32) -> UInt32? {
        let lBase: UInt32 = 0x1100, vBase: UInt32 = 0x1161, tBase: UInt32 = 0x11A7, sBase: UInt32 = 0xAC00
        let lCount: UInt32 = 19, vCount: UInt32 = 21, tCount: UInt32 = 28, nCount = vCount * tCount, sCount = lCount * nCount
        if first >= lBase && first < lBase + lCount && second >= vBase && second < vBase + vCount {
            return sBase + ((first - lBase) * vCount + (second - vBase)) * tCount
        }
        if first >= sBase && first < sBase + sCount && (first - sBase) % tCount == 0 && second > tBase && second < tBase + tCount {
            return first + second - tBase
        }
        return nil
    }

    static func decompositionMapping(_ scalar: UInt32) -> [UInt32]? {
        guard let index = binarySearch(scalar, in: Unicode15_1Generated.decompositionKeys) else { return nil }
        let offsets = Unicode15_1Generated.decompositionOffsets
        return Array(Unicode15_1Generated.decompositionValues[Int(offsets[index])..<Int(offsets[index + 1])])
    }

    static func caseFoldMapping(_ scalar: UInt32) -> [UInt32]? {
        guard let index = binarySearch(scalar, in: Unicode15_1Generated.caseFoldKeys) else { return nil }
        let offsets = Unicode15_1Generated.caseFoldOffsets
        return Array(Unicode15_1Generated.caseFoldValues[Int(offsets[index])..<Int(offsets[index + 1])])
    }

    static func combiningClass(_ scalar: UInt32) -> UInt32 {
        // The decomposition table includes only the code points we need to
        // distinguish here.  A binary search keeps the generated source compact.
        guard let index = binarySearch(scalar, in: canonicalCombiningClassKeys) else { return 0 }
        return canonicalCombiningClassValues[index]
    }

    static func composition(_ first: UInt32, _ second: UInt32) -> UInt32? {
        let triples = Unicode15_1Generated.compositionTriples
        var low = 0
        var high = triples.count / 3
        while low < high {
            let middle = (low + high) / 2
            let offset = middle * 3
            let left = triples[offset]
            let right = triples[offset + 1]
            if (first, second) < (left, right) {
                high = middle
            } else if (first, second) > (left, right) {
                low = middle + 1
            } else {
                return triples[offset + 2]
            }
        }
        return nil
    }

    static func binarySearch(_ needle: UInt32, in haystack: [UInt32]) -> Int? {
        var low = 0
        var high = haystack.count
        while low < high {
            let middle = (low + high) / 2
            if haystack[middle] < needle { low = middle + 1 } else { high = middle }
        }
        return low < haystack.count && haystack[low] == needle ? low : nil
    }

    static func string(_ scalars: [UInt32]) -> String {
        String(String.UnicodeScalarView(scalars.compactMap(Unicode.Scalar.init)))
    }

    static let canonicalCombiningClassKeys = Unicode15_1Generated.combiningClassKeys
    static let canonicalCombiningClassValues = Unicode15_1Generated.combiningClassValues
}

private extension Unicode15_1 {
    static func shouldBreak(
        leftIndex: Int,
        rightIndex: Int,
        scalars: [UInt32],
        properties: [WordBreakProperty]
    ) -> Bool {
        let left = properties[leftIndex]
        let right = properties[rightIndex]
        // WB3 through WB3d.
        if left == .cr && right == .lf { return false }
        if isNewline(left) || isNewline(right) { return true }
        if left == .zwj && right == .extendedPictographic { return false }
        if left == .wSegSpace && right == .wSegSpace { return false }

        // WB4. A formatting/extend scalar belongs to the word on its left. The
        // start-of-text exception is covered by the default boundary.
        if isIgnored(right) { return false }

        let significant = significantProperties(around: leftIndex, rightIndex, properties: properties)
        let a = significant.left
        let b = significant.right
        let beforeA = significant.beforeLeft
        let afterB = significant.afterRight

        if isAHLetter(a) && isAHLetter(b) { return false } // WB5
        if isAHLetter(a) && isMidLetterOrMidNumLetQ(b) && isAHLetter(afterB) { return false } // WB6
        if isAHLetter(beforeA) && isMidLetterOrMidNumLetQ(a) && isAHLetter(b) { return false } // WB7
        if a == .hebrewLetter && b == .singleQuote { return false } // WB7a
        if a == .hebrewLetter && b == .doubleQuote && afterB == .hebrewLetter { return false } // WB7b
        if beforeA == .hebrewLetter && a == .doubleQuote && b == .hebrewLetter { return false } // WB7c
        if a == .numeric && b == .numeric { return false } // WB8
        if isAHLetter(a) && b == .numeric { return false } // WB9
        if a == .numeric && isAHLetter(b) { return false } // WB10
        if a == .numeric && isMidNumOrMidNumLetQ(b) && afterB == .numeric { return false } // WB11
        if beforeA == .numeric && isMidNumOrMidNumLetQ(a) && b == .numeric { return false } // WB12
        if a == .katakana && b == .katakana { return false } // WB13
        if isAHLetterNumericKatakanaOrExtendNumLet(a) && b == .extendNumLet { return false } // WB13a
        if a == .extendNumLet && isAHLetterNumericKatakana(b) { return false } // WB13b
        if a == .regionalIndicator && b == .regionalIndicator && precedingRI(leftIndex, properties: properties).isMultiple(of: 2) == false { return false } // WB15/16
        return true // WB999
    }

    static func significantProperties(around left: Int, _ right: Int, properties: [WordBreakProperty]) -> (beforeLeft: WordBreakProperty, left: WordBreakProperty, right: WordBreakProperty, afterRight: WordBreakProperty) {
        func previousIndex(_ index: Int) -> Int? {
            var cursor = index
            while cursor >= 0 {
                if !isIgnored(properties[cursor]) { return cursor }
                cursor -= 1
            }
            return nil
        }
        func nextIndex(_ index: Int) -> Int? {
            var cursor = index
            while cursor < properties.count {
                if !isIgnored(properties[cursor]) { return cursor }
                cursor += 1
            }
            return nil
        }
        let leftIndex = previousIndex(left)
        let rightIndex = nextIndex(right)
        let a = leftIndex.map { properties[$0] } ?? .other
        let b = rightIndex.map { properties[$0] } ?? .other
        let before = leftIndex.flatMap { previousIndex($0 - 1) }.map { properties[$0] } ?? .other
        let after = rightIndex.flatMap { nextIndex($0 + 1) }.map { properties[$0] } ?? .other
        return (before, a, b, after)
    }

    static func precedingRI(_ index: Int, properties: [WordBreakProperty]) -> Int {
        var count = 0
        var cursor = index
        while cursor >= 0 {
            let property = properties[cursor]
            if isIgnored(property) { cursor -= 1; continue }
            guard property == .regionalIndicator else { break }
            count += 1
            cursor -= 1
        }
        return count
    }

    static func isNewline(_ property: WordBreakProperty) -> Bool { property == .cr || property == .lf || property == .newline }
    static func isIgnored(_ property: WordBreakProperty) -> Bool { property == .extend || property == .format || property == .zwj }
    static func isAHLetter(_ property: WordBreakProperty) -> Bool { property == .aLetter || property == .hebrewLetter }
    static func isMidLetterOrMidNumLetQ(_ property: WordBreakProperty) -> Bool { property == .midLetter || property == .midNumLet || property == .singleQuote }
    static func isMidNumOrMidNumLetQ(_ property: WordBreakProperty) -> Bool { property == .midNum || property == .midNumLet || property == .singleQuote }
    static func isAHLetterNumericKatakana(_ property: WordBreakProperty) -> Bool { isAHLetter(property) || property == .numeric || property == .katakana }
    static func isAHLetterNumericKatakanaOrExtendNumLet(_ property: WordBreakProperty) -> Bool { isAHLetterNumericKatakana(property) || property == .extendNumLet }
}
