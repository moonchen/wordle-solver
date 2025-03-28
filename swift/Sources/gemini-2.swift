import Atomics  // For progress counter
import Dispatch  // For printQueue
import Foundation  // For file loading, Date/TimeInterval

// import os // Not needed

// --- Main Application Struct ---
@main
struct WordleSolverApp {

    // --- Constants ---
    static let WORD_LENGTH = 5
    static let WORD_LIST_FILE = "valid-wordle-words.txt"
    static let EVALUATE_ALL_WORDS_AS_GUESSES = true
    static let MAX_RESULTS_TO_SHOW = 10
    static let MAX_SOLUTIONS_TO_PRINT = 10
    // static let REFINE_TOP_N_CANDIDATES = 50 // Removed

    // --- Type Aliases ---
    typealias Word = [Character]
    typealias FeedbackPattern = [Character]
    typealias FeedbackIndex = Int

    // --- Bitmask Helpers ---
    @inline(__always) static func charToBitIndex(_ c: Character) -> Int {
        return Int(c.asciiValue! - 97 /* Character("a").asciiValue!*/)
    }
    @inline(__always) static func charToMask(_ c: Character) -> UInt32 {
        let i = charToBitIndex(c)
        return (i >= 0 && i < 26) ? (1 << i) : 0
    }
    @inline(__always) static func isSet(_ mask: UInt32, _ c: Character) -> Bool {
        let cm = charToMask(c)
        return cm != 0 && (mask & cm) != 0
    }

    // --- GameState Struct ---
    struct GameState: Hashable, Equatable {
        var greens: Word
        var yellowsMask: UInt32
        var greysMask: UInt32
        init(
            greens: Word = Array(repeating: "_", count: WORD_LENGTH), yMask: UInt32 = 0,
            gMask: UInt32 = 0
        ) {
            self.greens = greens
            self.yellowsMask = yMask
            self.greysMask = gMask
        }
    }

    // --- feedbackPatternToIndex (Only needed if using heuristic score) ---
    @inline(__always) static func feedbackPatternToIndex(feedbackPattern: FeedbackPattern) -> Int {
        let p = Array(feedbackPattern)
        var i = 0
        i += (p[0] == "Y") ? 1 : ((p[0] == "G") ? 2 : 0)
        i += ((p[1] == "Y") ? 1 : ((p[1] == "G") ? 2 : 0)) * 3
        i += ((p[2] == "Y") ? 1 : ((p[2] == "G") ? 2 : 0)) * 9
        i += ((p[3] == "Y") ? 1 : ((p[3] == "G") ? 2 : 0)) * 27
        i += ((p[4] == "Y") ? 1 : ((p[4] == "G") ? 2 : 0)) * 81
        return i
    }

    static func getFeedback(guess: Word, actual: Word) -> FeedbackIndex {
        var usedGuessIndicesMask: UInt8 = 0
        // Use a single UInt64 to store counts. 2 bits per letter (indices 0-25).
        // Bits 0-1 for 'a', 2-3 for 'b', ..., 50-51 for 'z'.
        var actualCountsPacked: UInt64 = 0

        // --- Count characters using bit packing ---
        for char in actual {
            let charIndex = Self.charToBitIndex(char)
            let shift = charIndex * 2 // Starting bit position for this char
            let mask: UInt64 = 3 << shift // Mask for the 2 bits (0b11 shifted)

            // Read current count (0-3)
            let currentCount = (actualCountsPacked >> shift) & 3

            // Increment count (ignore overflow as requested, max count is 3 with 2 bits)
            let newCount = currentCount + 1
            // newValue &= 3 // would normally cap at 3 if overflow wasn't ignored

            // Clear the 2 bits and set the new value
            actualCountsPacked = (actualCountsPacked & ~mask) | (newCount << shift)
        }
        // --- End Counting ---

        var index: FeedbackIndex = 0
        var powerOf3 = 1 // Start with 3^0 for position 0

        // Pass 1: Find Greens, calculate their contribution, decrement packed count, update mask
        for i in 0..<WORD_LENGTH {
            if guess[i] == actual[i] {
                index += 2 * powerOf3 // Green = digit 2

                let charIndex = Self.charToBitIndex(guess[i])
                let shift = charIndex * 2
                let mask: UInt64 = 3 << shift

                // Read current count
                let currentCount = (actualCountsPacked >> shift) & 3

                // Decrement count if > 0
                if currentCount > 0 {
                    let newCount = currentCount - 1
                    // Clear the 2 bits and set the new value
                    actualCountsPacked = (actualCountsPacked & ~mask) | (newCount << shift)
                }
                // else: count was already 0, nothing to decrement

                usedGuessIndicesMask |= (1 << i) // Set used bit
            }
            powerOf3 *= 3 // Move to next power/position
        }

        powerOf3 = 1 // Reset power for position 0 for the second pass
        // Pass 2: Find Yellows, calculate their contribution, decrement packed count
        for i in 0..<WORD_LENGTH {
            // Check if the i-th bit is NOT set in the mask
            if (usedGuessIndicesMask & (1 << i)) == 0 { // Only consider non-green positions
                let guessChar = guess[i]
                let charIndex = Self.charToBitIndex(guessChar)
                let shift = charIndex * 2
                let mask: UInt64 = 3 << shift

                // Read current count
                let currentCount = (actualCountsPacked >> shift) & 3

                // Check if count > 0
                if currentCount > 0 {
                    index += 1 * powerOf3 // Yellow = digit 1

                    // Decrement count
                    let newCount = currentCount - 1
                    // Clear the 2 bits and set the new value
                    actualCountsPacked = (actualCountsPacked & ~mask) | (newCount << shift)
                }
                // If not Green and not Yellow (count was 0), digit is 0, add 0 * powerOf3
            }
            powerOf3 *= 3 // Move to next power/position
        }
        return index
    }

    // --- combine_feedback ---
    static func combineFeedback(currentState: GameState, guess: Word, feedbackIndex: FeedbackIndex)
        -> GameState
    {
        var nextState = currentState
        var gMask: UInt32 = 0
        var yMask: UInt32 = 0
        var grMask: UInt32 = 0
        var nextGreensChars = currentState.greens
        var remainingIndex = feedbackIndex

        // Decode feedback digits in base 3 (position 0 is the least significant digit)
        for i in 0..<WORD_LENGTH {
            let digit = remainingIndex % 3
            remainingIndex /= 3
            let guessChar = guess[i]
            let cm = Self.charToMask(guessChar)

            if digit == 2 {  // Green feedback
                nextGreensChars[i] = guessChar
                gMask |= cm
            } else if digit == 1 {  // Yellow feedback
                yMask |= cm
            } else {  // Gray feedback (digit == 0)
                grMask |= cm
            }
        }

        nextState.greens = nextGreensChars
        nextState.yellowsMask |= (yMask & ~gMask)
        nextState.greysMask |= (grMask & ~gMask & ~nextState.yellowsMask)
        nextState.yellowsMask &= ~gMask
        nextState.greysMask &= ~(gMask | nextState.yellowsMask)
        return nextState
    }

    // --- calculateGuessScore (Using Accurate State Aggregation) ---
    // Renamed from calculateAccurateScore back to primary name
    static func calculateGuessScore(
        currentState: GameState,
        candidateGuess: Word,
        possibleSolutions: [Word]
    ) -> Int {
        guard !possibleSolutions.isEmpty else { return 0 }

        // Use Dictionary with GameState as key to group results
        var feedbackGroups: [FeedbackIndex: Int] = [:]
        var nextStateGroups: [GameState: Int] = [:]
        // Reserving might help, but max size isn't strictly 243 anymore
        feedbackGroups.reserveCapacity(min(243, possibleSolutions.count))

        // This loop runs for *every* possible solution
        // var actualCounts: [Int8] = Array(repeating: 0, count: 26)
        for actualSolution in possibleSolutions {
            let fp = Self.getFeedback(guess: candidateGuess, actual: actualSolution)

            feedbackGroups[fp, default: 0] += 1
        }

        for feedbackGroup in feedbackGroups {
            let nextState = Self.combineFeedback(
                currentState: currentState,
                guess: candidateGuess,
                feedbackIndex: feedbackGroup.key)
            nextStateGroups[nextState, default: 0] += feedbackGroup.value
        }

        // Find the max count among the final aggregated states
        let maxGroupSize = nextStateGroups.values.max() ?? 0

        // Sanity check
        if possibleSolutions.count > 0 && maxGroupSize == 0 && !nextStateGroups.isEmpty {
            fputs("Warning: Max group size 0 despite non-empty feedback groups.\n", stderr)
            return Int.max
        } else if possibleSolutions.count > 0 && nextStateGroups.isEmpty {
            fputs(
                "Warning: No feedback groups generated despite \(possibleSolutions.count) possible solutions.\n",
                stderr)
            return Int.max
        }

        return maxGroupSize
    }

    // --- filter_words ---
    static func filterWords(
        words: [Word], greensPattern: Word, yellowsMask: UInt32, greysMask: UInt32
    ) -> [Word] {
        var possibleSolutions: [Word] = []
        possibleSolutions.reserveCapacity(words.count / 10)
        let greensPatternChars = greensPattern
        var greenCharsMask: UInt32 = 0
        var greenCounts: [Character: Int] = [:]
        for i in 0..<WORD_LENGTH {
            let c = greensPatternChars[i]
            if c != "_" {
                greenCharsMask |= Self.charToMask(c)
                greenCounts[c, default: 0] += 1
            }
        }
        var minTotalCounts = greenCounts
        for asciiValue in Character("a").asciiValue!...Character("z").asciiValue! {
            let c = Character(UnicodeScalar(asciiValue))
            if Self.isSet(yellowsMask, c) {
                minTotalCounts[c, default: 0] = max(minTotalCounts[c, default: 0] + 1, 1)
            }
        }
        let strictGreysMask = greysMask & ~greenCharsMask & ~yellowsMask
        wordLoop: for word in words {
            var wordCounts: [Character: Int] = [:]
            var wordCharsMask: UInt32 = 0
            let wordChars = word
            for i in 0..<WORD_LENGTH {
                let c = wordChars[i]
                wordCounts[c, default: 0] += 1
                wordCharsMask |= Self.charToMask(c)
            }
            for i in 0..<WORD_LENGTH {
                if greensPatternChars[i] != "_" && greensPatternChars[i] != wordChars[i] {
                    continue wordLoop
                }
            }
            if (wordCharsMask & strictGreysMask) != 0 { continue wordLoop }
            for asciiValue in Character("a").asciiValue!...Character("z").asciiValue! {
                let c = Character(UnicodeScalar(asciiValue))
                let wc = wordCounts[c, default: 0]
                let min_c = minTotalCounts[c, default: 0]
                if wc < min_c { continue wordLoop }
                if Self.isSet(greysMask, c) {
                    let green_c = greenCounts[c, default: 0]
                    if wc != green_c { continue wordLoop }
                }
            }
            possibleSolutions.append(word)
        }
        return possibleSolutions
    }

    // --- wordToUpper ---
    static func wordToUpper(_ w: Word) -> String {
        return String(w.map { Character($0.uppercased()) })
    }

    // --- load_words ---
    static func loadWords(from filename: String) -> [Word]? {
        let fileURL = URL(fileURLWithPath: filename)
        guard let fileContents = try? String(contentsOf: fileURL, encoding: .utf8) else {
            fputs("Error: Cannot open \(filename)\n", stderr)
            return nil
        }
        var uniqueWords = Set<[Character]>()
        let lines = fileContents.split(separator: "\n", omittingEmptySubsequences: true)
        for line in lines {
            let trimmedLine = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmedLine.count == WORD_LENGTH else { continue }
            let lowerLine = trimmedLine.lowercased()
            var allValidChars = true
            for char in lowerLine {
                guard char >= "a" && char <= "z" else {
                    allValidChars = false
                    break
                }
            }
            if allValidChars { uniqueWords.insert(Array(lowerLine)) }
        }
        if uniqueWords.isEmpty {
            fputs("Error: No valid words found in \(filename)\n", stderr)
            return nil
        }
        return Array(uniqueWords).sorted { String($0) < String($1) }
    }

    // --- Main Static Function ---
    static func main() async {
        // 1. Argument Parsing and Validation
        guard CommandLine.arguments.count == 4 else { /* Usage */
            fputs("Usage: ...\n", stderr)
            exit(1)
        }
        let overallStartTime = Date()
        // ... Arg parsing ...
        let greensInputStr = CommandLine.arguments[1].lowercased()
        let yellowsInputStr = CommandLine.arguments[2].lowercased()
        let greysInputStr = CommandLine.arguments[3].lowercased()
        guard greensInputStr.count == WORD_LENGTH else {
            fputs("E: Greens length invalid.\n", stderr)
            exit(1)
        }
        var initialGreensWord: Word = Array(repeating: "_", count: WORD_LENGTH)
        for (i, char) in greensInputStr.enumerated() {
            guard char == "_" || (char >= "a" && char <= "z") else {
                fputs("E: Greens invalid char.\n", stderr)
                exit(1)
            }
            if char != "_" { initialGreensWord[i] = char }
        }
        var initialYellowsMask: UInt32 = 0
        if yellowsInputStr != "_" {
            for char in yellowsInputStr {
                guard char >= "a" && char <= "z" else {
                    fputs("E: Yellows invalid char.\n", stderr)
                    exit(1)
                }
                initialYellowsMask |= Self.charToMask(char)
            }
        }
        var initialGreysMask: UInt32 = 0
        if greysInputStr != "_" {
            for char in greysInputStr {
                guard char >= "a" && char <= "z" else {
                    fputs("E: Greys invalid char.\n", stderr)
                    exit(1)
                }
                initialGreysMask |= Self.charToMask(char)
            }
        }
        var initialGameState = GameState(
            greens: initialGreensWord, yMask: initialYellowsMask, gMask: initialGreysMask)
        var initialGreenCharsMask: UInt32 = 0
        for char in initialGameState.greens {
            if char != "_" { initialGreenCharsMask |= Self.charToMask(char) }
        }
        initialGameState.yellowsMask &= ~initialGreenCharsMask
        initialGameState.greysMask &= ~(initialGreenCharsMask | initialGameState.yellowsMask)

        // 2. Load Word List
        print("Loading word list from '\(Self.WORD_LIST_FILE)'...")
        let loadStartTime = Date()
        guard let allValidWords: [Word] = Self.loadWords(from: Self.WORD_LIST_FILE) else { exit(1) }
        let loadDuration = Date().timeIntervalSince(loadStartTime)
        print(
            "Loaded \(allValidWords.count) valid words. (\(String(format:"%.2f", loadDuration))s)")

        // 3. Filter Remaining Possible Solutions
        print("\nFiltering possible solutions...")
        let filterStartTime = Date()
        let possibleSolutions: [Word] = Self.filterWords(
            words: allValidWords, greensPattern: initialGameState.greens,
            yellowsMask: initialGameState.yellowsMask, greysMask: initialGameState.greysMask)
        let filterDuration = Date().timeIntervalSince(filterStartTime)
        print(
            "Found \(possibleSolutions.count) possible solutions matching criteria. (Filter time: \(String(format:"%.2f", filterDuration))s)"
        )
        if !possibleSolutions.isEmpty && possibleSolutions.count <= Self.MAX_SOLUTIONS_TO_PRINT
        { /* Print small list */
            print("\nPossible solutions (\(possibleSolutions.count) total):")
            let sortedSols = possibleSolutions.sorted { String($0) < String($1) }
            for sol in sortedSols { print("- \(Self.wordToUpper(sol))") }
        }

        // 4. Handle Edge Cases
        guard !possibleSolutions.isEmpty else {
            print("\nNo possible words match criteria.")
            exit(0)
        }
        guard possibleSolutions.count > 2 else { /* Handle 1 or 2 */
            if possibleSolutions.count == 1 {
                print("\nSolution found.")
            } else {
                print("\nOnly 2 solutions left.")
            }
            exit(0)
        }

        // 5. Evaluate Potential Next Guesses (Using TaskGroup, Accurate Score)
        print("\nEvaluating best next guesses (Parallel TaskGroup, Accurate Score)...")  // Message reflects accurate score
        let evalStartTime = Date()
        let guessCandidates: [Word] =
            Self.EVALUATE_ALL_WORDS_AS_GUESSES ? allValidWords : possibleSolutions
        let totalCandidates = guessCandidates.count
        var guessScores = [(guess: Word, score: Int)](
            repeating: (guess: [], score: 0), count: totalCandidates)
        let evaluatedCount = ManagedAtomic<Int>(0)
        let progressInterval = max(1, totalCandidates / 100)
        let printQueue = DispatchQueue(label: "com.wordle.printQueue")
        typealias ScoreResult = (index: Int, guess: Word, score: Int)

        // --- Evaluation Loop with TaskGroup ---
        await withTaskGroup(of: ScoreResult.self) { group in
            for i in 0..<totalCandidates {
                let candidate = guessCandidates[i]
                let state = initialGameState
                let solutions = possibleSolutions

                group.addTask {
                    // Call the ACCURATE scorer
                    let score = Self.calculateGuessScore(
                        currentState: state,
                        candidateGuess: candidate,
                        possibleSolutions: solutions)
                    // Progress reporting...
                    let currentCount = evaluatedCount.wrappingIncrementThenLoad(ordering: .relaxed)
                    if currentCount % progressInterval == 0 || currentCount == totalCandidates {
                        printQueue.async {
                            let elapsedSeconds = Date().timeIntervalSince(evalStartTime)
                            let rate =
                                elapsedSeconds > 0 ? Double(currentCount) / elapsedSeconds : 0.0
                            print(
                                String(
                                    format:
                                        "  Evaluated %d/%d... (Elapsed: %.1fs, %.1f per second)   \r",
                                    currentCount, totalCandidates, elapsedSeconds, rate),
                                terminator: "")
                            fflush(stdout)
                        }
                    }
                    return (index: i, guess: candidate, score: score)
                }
            }  // End addTask loop
            // Collect results
            for await result in group {
                guessScores[result.index] = (guess: result.guess, score: result.score)
            }
        }  // End TaskGroup

        print("")  // Newline
        let evalDuration = Date().timeIntervalSince(evalStartTime)
        print("Evaluation complete. (Eval time: \(String(format:"%.2f", evalDuration))s)")

        // 6. Rank and Select Best Guesses
        let possibleSolutionsSet = Set(possibleSolutions)
        guessScores.sort { (a, b) -> Bool in
            if a.score != b.score { return a.score < b.score }
            let aP = possibleSolutionsSet.contains(a.guess)
            let bP = possibleSolutionsSet.contains(b.guess)
            return aP && !bP
        }

        // 7. Output Results
        if let bestScore = guessScores.first?.score {
            print("\nBest score: \(bestScore)")
        } else {
            print("\nNo valid guesses.")
        }
        print("Top guesses:")
        var count = 0
        var showedMarker = false
        for entry in guessScores {
            guard count < Self.MAX_RESULTS_TO_SHOW else { break }
            let marker = possibleSolutionsSet.contains(entry.guess) ? "*" : ""
            if !marker.isEmpty { showedMarker = true }
            print(
                "  \(count + 1). \(Self.wordToUpper(entry.guess)) (Score: \(entry.score))\(marker)")
            count += 1
        }
        if showedMarker { print("\n  (*) = Possible solution.") }

        let overallDuration = Date().timeIntervalSince(overallStartTime)
        print("\nTotal execution time: \(String(format:"%.2f", overallDuration))s")
    }  // End main
}  // End struct
