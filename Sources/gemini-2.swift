import Atomics
import Dispatch
import Foundation

// import os // Not needed now

// --- Main Application Struct ---
@main
struct WordleSolverApp {

    // --- Move Constants Inside ---
    static let WORD_LENGTH = 5
    static let WORD_LIST_FILE = "valid-wordle-words.txt"
    static let EVALUATE_ALL_WORDS_AS_GUESSES = true
    static let MAX_RESULTS_TO_SHOW = 10
    static let MAX_SOLUTIONS_TO_PRINT = 10

    // --- Move Type Alias Inside ---
    typealias Word = String

    // --- Move Bitmask Helpers Inside (make static) ---
    @inline(__always)
    static func charToBitIndex(_ c: Character) -> Int {
        return Int(c.asciiValue! - Character("a").asciiValue!)
    }
    @inline(__always)
    static func charToMask(_ c: Character) -> UInt32 {
        let i = charToBitIndex(c)
        return (i >= 0 && i < 26) ? (1 << i) : 0
    }
    @inline(__always)
    static func isSet(_ mask: UInt32, _ c: Character) -> Bool {
        let cm = charToMask(c)
        return cm != 0 && (mask & cm) != 0
    }

    // --- Move GameState Struct Inside (or keep outside if preferred, but must be Sendable if passed across actors implicitly) ---
    // Keeping it inside is often cleaner for @main structure
    struct GameState: Hashable, Equatable /*, Sendable */ {  // Add Sendable if needed for future actor use
        var greens: Word
        var yellowsMask: UInt32
        var greysMask: UInt32
        init(
            greens: Word = String(repeating: "_", count: WORD_LENGTH),
            yellowsMask: UInt32 = 0,
            greysMask: UInt32 = 0
        ) {
            self.greens = greens
            self.yellowsMask = yellowsMask
            self.greysMask = greysMask
        }
    }

    // --- get_feedback Implementation (Using String Indices) ---
    // Assumes guess and actual contain only 'a'-'z'
    func getFeedback(guess: Word, actual: Word) -> Word {
        // Use indices - more complex but avoids Array allocation for guess/actual
        let guessStartIndex = guess.startIndex
        let actualStartIndex = actual.startIndex

        // feedbackChars still seems necessary to build the result easily
        var feedbackChars = [Character](repeating: "_", count: WordleSolverApp.WORD_LENGTH)

        // These small arrays are likely stack-allocated and fast enough
        var usedGuessIndices = [Bool](repeating: false, count: WordleSolverApp.WORD_LENGTH)
        var actualCounts = [Int](repeating: 0, count: 26)  // Stack allocation

        // Count characters in the actual word using indices
        var actualIndex = actualStartIndex
        for _ in 0..<WordleSolverApp.WORD_LENGTH {
            let char = actual[actualIndex]
            actualCounts[WordleSolverApp.charToBitIndex(char)] += 1
            actual.formIndex(after: &actualIndex)  // Move to next index
        }

        // Pass 1: Find Greens using indices
        var guessIndex = guessStartIndex
        actualIndex = actualStartIndex  // Reset actual index
        for i in 0..<WordleSolverApp.WORD_LENGTH {
            let guessChar = guess[guessIndex]
            let actualChar = actual[actualIndex]

            if guessChar == actualChar {
                feedbackChars[i] = "G"
                actualCounts[WordleSolverApp.charToBitIndex(guessChar)] -= 1
                usedGuessIndices[i] = true
            }
            // Move to next indices
            guess.formIndex(after: &guessIndex)
            actual.formIndex(after: &actualIndex)
        }

        // Pass 2: Find Yellows using indices
        guessIndex = guessStartIndex  // Reset guess index
        for i in 0..<WordleSolverApp.WORD_LENGTH {
            let guessChar = guess[guessIndex]  // Get char at current index

            if !usedGuessIndices[i] {  // Check bool array first
                let indexInCounts = WordleSolverApp.charToBitIndex(guessChar)
                if actualCounts[indexInCounts] > 0 {
                    feedbackChars[i] = "Y"
                    actualCounts[indexInCounts] -= 1
                }
            }
            guess.formIndex(after: &guessIndex)  // Move to next index
        }

        return String(feedbackChars)  // Final String creation
    }

    static func combineFeedback(currentState: GameState, guess: Word, feedbackPattern: Word)
        -> GameState
    {
        var nextState = currentState
        var gMask: UInt32 = 0
        var yMask: UInt32 = 0
        var grMask: UInt32 = 0
        let guessChars = Array(guess)
        let patternChars = Array(feedbackPattern)
        var nextGreensChars = Array(nextState.greens)
        for i in 0..<WORD_LENGTH {
            let gc = guessChars[i]
            let fc = patternChars[i]
            let cm = charToMask(gc)
            if fc == "G" {
                nextGreensChars[i] = gc
                gMask |= cm
            } else if fc == "Y" {
                yMask |= cm
            } else {
                grMask |= cm
            }
        }
        nextState.greens = String(nextGreensChars)
        nextState.yellowsMask |= (yMask & ~gMask)
        nextState.greysMask |= (grMask & ~gMask & ~nextState.yellowsMask)
        nextState.yellowsMask &= ~gMask
        nextState.greysMask &= ~(gMask | nextState.yellowsMask)
        return nextState
    }

    @inline(__always)
    func feedbackPatternToIndex(feedbackPattern: Word) -> Int {
        let p = Array(feedbackPattern)
        var i = 0
        i += (p[0] == "Y") ? 1 : ((p[0] == "G") ? 2 : 0)
        i += ((p[1] == "Y") ? 1 : ((p[1] == "G") ? 2 : 0)) * 3
        i += ((p[2] == "Y") ? 1 : ((p[2] == "G") ? 2 : 0)) * 9
        i += ((p[3] == "Y") ? 1 : ((p[3] == "G") ? 2 : 0)) * 27
        i += ((p[4] == "Y") ? 1 : ((p[4] == "G") ? 2 : 0)) * 81
        return i
    }

    func calculateGuessScore(
        currentState: GameState, candidateGuess: Word, possibleSolutions: [Word]
    ) -> Int {
        guard !possibleSolutions.isEmpty else { return 0 }
        let maxPatterns = 243
        var groupCounts = [Int](repeating: 0, count: maxPatterns)
        for actualSolution in possibleSolutions {
            let fp = getFeedback(guess: candidateGuess, actual: actualSolution)
            let idx = feedbackPatternToIndex(feedbackPattern: fp)
            if idx >= 0 && idx < maxPatterns {
                groupCounts[idx] += 1
            } else {
                fputs("Warning: Invalid feedback pattern index \(idx)\n", stderr)
            }
        }
        let maxGroupSize = groupCounts.max() ?? 0
        if possibleSolutions.count > 0 && maxGroupSize == 0 {
            fputs(
                "Warning: Max group size 0 despite \(possibleSolutions.count) possible solutions.\n",
                stderr)
            return Int.max
        }
        return maxGroupSize
    }

    static func filterWords(
        words: [Word], greensPattern: Word, yellowsMask: UInt32, greysMask: UInt32
    ) -> [Word] {
        var possibleSolutions: [Word] = []
        let greensPatternChars = Array(greensPattern)
        var greenCharsMask: UInt32 = 0
        var greenCounts: [Character: Int] = [:]
        for i in 0..<WORD_LENGTH {
            let c = greensPatternChars[i]
            if c != "_" {
                greenCharsMask |= charToMask(c)
                greenCounts[c, default: 0] += 1
            }
        }  // Use static method
        var minTotalCounts = greenCounts
        for asciiValue in Character("a").asciiValue!...Character("z").asciiValue! {
            let c = Character(UnicodeScalar(asciiValue))
            if isSet(yellowsMask, c) {
                minTotalCounts[c, default: 0] = max(minTotalCounts[c, default: 0] + 1, 1)
            }
        }  // Use static method
        let strictGreysMask = greysMask & ~greenCharsMask & ~yellowsMask
        wordLoop: for word in words {
            var wordCounts: [Character: Int] = [:]
            var wordCharsMask: UInt32 = 0
            let wordChars = Array(word)
            for i in 0..<WORD_LENGTH {
                let c = wordChars[i]
                wordCounts[c, default: 0] += 1
                wordCharsMask |= charToMask(c)
            }  // Use static method
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
                if isSet(greysMask, c) {
                    let green_c = greenCounts[c, default: 0]
                    if wc != green_c { continue wordLoop }
                }  // Use static method
            }
            possibleSolutions.append(word)
        }
        return possibleSolutions
    }

    static func wordToUpper(_ w: Word) -> String { return w.uppercased() }

    static func loadWords(from filename: String) -> [Word]? {
        let fileURL = URL(fileURLWithPath: filename)
        guard let fileContents = try? String(contentsOf: fileURL, encoding: .utf8) else {
            fputs("Error: Cannot open \(filename)\n", stderr)
            return nil
        }
        var uniqueWords = Set<Word>()
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
            if allValidChars { uniqueWords.insert(lowerLine) }
        }
        if uniqueWords.isEmpty {
            fputs("Error: No valid words found in \(filename)\n", stderr)
            return nil
        }
        return Array(uniqueWords).sorted()
    }

    // --- Main Static Function ---
    static func main() async {
        // 1. Argument Parsing and Validation
        guard CommandLine.arguments.count == 4 else {
            fputs("Usage: ...\n", stderr)
            exit(1)
        }
        let overallStartTime = Date()  // Use Date for timing
        let greensInputStr = CommandLine.arguments[1].lowercased()
        let yellowsInputStr = CommandLine.arguments[2].lowercased()
        let greysInputStr = CommandLine.arguments[3].lowercased()
        guard greensInputStr.count == WORD_LENGTH else {
            fputs("E: Greens length invalid.\n", stderr)
            exit(1)
        }
        // Use static methods for helpers now
        let initialGreensWord: Word = greensInputStr
        var initialYellowsMask: UInt32 = 0
        var initialGreysMask: UInt32 = 0
        for char in greensInputStr {
            guard char == "_" || (char >= "a" && char <= "z") else {
                fputs("E: Greens invalid char.\n", stderr)
                exit(1)
            }
        }
        if yellowsInputStr != "_" {
            for char in yellowsInputStr {
                guard char >= "a" && char <= "z" else {
                    fputs("E: Yellows invalid char.\n", stderr)
                    exit(1)
                }
                initialYellowsMask |= Self.charToMask(char)
            }
        }  // Use Self. or WordleSolverApp.
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
            greens: initialGreensWord, yellowsMask: initialYellowsMask, greysMask: initialGreysMask)
        var initialGreenCharsMask: UInt32 = 0
        for char in initialGameState.greens {
            if char != "_" { initialGreenCharsMask |= Self.charToMask(char) }
        }
        initialGameState.yellowsMask &= ~initialGreenCharsMask
        initialGameState.greysMask &= ~(initialGreenCharsMask | initialGameState.yellowsMask)

        // 2. Load Word List
        print("Loading word list from '\(Self.WORD_LIST_FILE)'...")
        let loadStartTime = Date()  // Use Self. for constants
        guard let allValidWords = Self.loadWords(from: Self.WORD_LIST_FILE) else { exit(1) }
        let loadDuration = Date().timeIntervalSince(loadStartTime)  // Use Self.
        print(
            "Loaded \(allValidWords.count) valid words. (\(String(format:"%.2f", loadDuration))s)")

        // 3. Filter Remaining Possible Solutions
        print("\nFiltering possible solutions...")
        let filterStartTime = Date()
        let possibleSolutions = Self.filterWords(
            words: allValidWords, greensPattern: initialGameState.greens,
            yellowsMask: initialGameState.yellowsMask, greysMask: initialGameState.greysMask)  // Use Self.
        let filterDuration = Date().timeIntervalSince(filterStartTime)
        print(
            "Found \(possibleSolutions.count) possible solutions matching criteria. (Filter time: \(String(format:"%.2f", filterDuration))s)"
        )
        if !possibleSolutions.isEmpty && possibleSolutions.count <= Self.MAX_SOLUTIONS_TO_PRINT {
            print("\nPossible solutions (\(possibleSolutions.count) total):")
            for sol in possibleSolutions.sorted() { print("- \(Self.wordToUpper(sol))") }
        }  // Use Self.

        // 4. Handle Edge Cases
        guard !possibleSolutions.isEmpty else {
            print("\nNo possible words match criteria.")
            exit(0)
        }
        guard possibleSolutions.count > 2 else {
            if possibleSolutions.count == 1 {
                print("\nSolution found.")
            } else {
                print("\nOnly 2 solutions left.")
            }
            exit(0)
        }

        // 5. Evaluate Potential Next Guesses (Using TaskGroup)
        print("\nEvaluating best next guesses (Parallel TaskGroup)...")
        let evalStartTime = Date()
        let guessCandidates: [Word] =
            Self.EVALUATE_ALL_WORDS_AS_GUESSES ? allValidWords : possibleSolutions  // Use Self.
        let totalCandidates = guessCandidates.count
        var guessScores = [(guess: Word, score: Int)](
            repeating: (guess: "", score: 0), count: totalCandidates)
        let evaluatedCount = ManagedAtomic<Int>(0)
        let progressInterval = max(1, totalCandidates / 100)
        let printQueue = DispatchQueue(label: "com.wordle.printQueue")
        typealias ScoreResult = (index: Int, guess: Word, score: Int)

        // --- Evaluation Loop with TaskGroup ---
        let solver = WordleSolverApp()
        await withTaskGroup(of: ScoreResult.self) { group in
            for i in 0..<totalCandidates {
                // Capture list can remain the same
                let candidate = guessCandidates[i]
                let state = initialGameState
                let solutions = possibleSolutions

                group.addTask {
                    // Call static method
                    let score = solver.calculateGuessScore(
                        currentState: state,
                        candidateGuess: candidate,
                        possibleSolutions: solutions)
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
            }  // End of addTask loop

            // --- Collect results (unchanged) ---
            for await result in group {
                guessScores[result.index] = (guess: result.guess, score: result.score)
            }
        }  // End TaskGroup

        print("")  // Newline after progress
        let evalDuration = Date().timeIntervalSince(evalStartTime)
        print("Evaluation complete. (Eval time: \(String(format:"%.2f", evalDuration))s)")

        // 6. Rank and Select Best Guesses (unchanged)
        let possibleSolutionsSet = Set(possibleSolutions)
        guessScores.sort { (a, b) -> Bool in
            if a.score != b.score { return a.score < b.score }
            let aP = possibleSolutionsSet.contains(a.guess)
            let bP = possibleSolutionsSet.contains(b.guess)
            return aP && !bP
        }

        // 7. Output Results (unchanged)
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
        }  // Use Self.
        if showedMarker { print("\n  (*) = Possible solution.") }

        let overallDuration = Date().timeIntervalSince(overallStartTime)
        print("\nTotal execution time: \(String(format:"%.2f", overallDuration))s")
    }  // End static func main
}  // End struct WordleSolverApp

// --- REMOVED Utility Extensions for ContinuousClock ---
