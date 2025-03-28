#include <algorithm> // For std::sort, std::max, std::copy, std::fill, std::transform, std::min
#include <array>         // For fixed-size Word arrays & count arrays
#include <cctype>        // For ::tolower, ::isalpha, ::toupper
#include <chrono>        // For timing execution
#include <cstdint>       // For uint32_t (bitmasks)
#include <cstring>       // For std::memcpy (in hash)
#include <fstream>       // For file loading
#include <functional>    // For std::hash
#include <iomanip>       // For std::setprecision, std::fixed
#include <iostream>      // For input/output (cout, cerr)
#include <limits>        // For std::numeric_limits
#include <omp.h>         // Include OpenMP header
#include <set>           // Used in load_words for uniqueness
#include <string>        // For string manipulation (input args, initial greens)
#include <unordered_map> // For grouping feedback results & counts in filters
#include <unordered_set> // For intermediate sets & final possible set lookup
#include <utility>       // For std::pair, std::move
#include <vector>        // For dynamic arrays (word lists, possible solutions)

// --- Configuration ---
const int WORD_LENGTH = 5;
const std::string WORD_LIST_FILE = "valid-wordle-words.txt";
const bool EVALUATE_ALL_WORDS_AS_GUESSES = true;
const int MAX_RESULTS_TO_SHOW = 10;
const int MAX_SOLUTIONS_TO_PRINT = 10;

// --- Type Alias for Word ---
using Word = std::array<char, WORD_LENGTH>;

// --- Bitmask Helper Functions (unchanged) ---
inline constexpr int char_to_bit_index(char c) { return c - 'a'; }
inline constexpr uint32_t char_to_mask(char c) { return 1u << (c - 'a'); }
inline bool is_set(uint32_t mask, char c) {
  return (mask & (1u << (c - 'a'))) != 0u;
}

// --- GameState Struct (unchanged) ---
struct GameState {
  Word greens;
  uint32_t yellows_mask;
  uint32_t greys_mask;
  GameState() : yellows_mask(0u), greys_mask(0u) {
    std::fill(greens.begin(), greens.end(), '_');
  }
  bool operator==(const GameState &other) const {
    return greens == other.greens && yellows_mask == other.yellows_mask &&
           greys_mask == other.greys_mask;
  }
};

// --- Hash Function for Word (unchanged) ---
struct WordHash {
  std::size_t operator()(const Word &w) const noexcept {
    uint64_t c = 0;
    std::memcpy(&c, w.data(), std::min(sizeof(c), sizeof(Word)));
    return std::hash<uint64_t>{}(c);
  }
};

// --- Hash Function for GameState (unchanged) ---
struct GameStateHash {
  WordHash word_hasher;
  template <class T>
  inline void hash_combine(std::size_t &s, const T &v) const {
    std::hash<T> h;
    s ^= h(v) + 0x9e3779b9 + (s << 6) + (s >> 2);
  }
  std::size_t operator()(const GameState &state) const noexcept {
    std::size_t s = 0;
    hash_combine(s, word_hasher(state.greens));
    hash_combine(s, state.yellows_mask);
    hash_combine(s, state.greys_mask);
    return s;
  }
};

// --- Function Prototypes ---
Word get_feedback(const Word &guess, const Word &actual);
GameState combine_feedback(const GameState &current_state, const Word &guess,
                           const Word &feedback_pattern);
int calculate_guess_score(const GameState &current_state,
                          const Word &candidate_guess,
                          const std::vector<Word> &possible_solutions);
std::vector<Word> filter_words(const std::vector<Word> &words,
                               const Word &greens_pattern,
                               uint32_t yellows_mask, uint32_t greys_mask);
std::ostream &operator<<(std::ostream &os, const Word &w);
Word word_to_upper(Word w);
std::string string_to_lower(std::string s);
std::string string_to_upper(std::string s);
std::vector<Word> load_words(const std::string &filename);
inline int feedback_pattern_to_index(const Word &feedback_pattern);

// --- get_feedback Implementation (Rolled Loops, No Safety Checks - unchanged)
// ---
Word get_feedback(const Word &guess, const Word &actual) {
  Word feedback;
  std::fill(feedback.begin(), feedback.end(), '_');
  std::array<bool, WORD_LENGTH> used_guess_indices{};
  std::array<int, 26> actual_counts{};
  for (char c : actual) {
    actual_counts[c - 'a']++;
  } // Assumes valid 'a'-'z'
  for (int i = 0; i < WORD_LENGTH; ++i) {
    if (guess[i] == actual[i]) {
      feedback[i] = 'G';
      actual_counts[guess[i] - 'a']--;
      used_guess_indices[i] = true;
    }
  } // Assumes valid 'a'-'z'
  for (int i = 0; i < WORD_LENGTH; ++i) {
    if (used_guess_indices[i])
      continue;
    char guess_char = guess[i];
    int index = guess_char - 'a';
    if (actual_counts[index] > 0) {
      feedback[i] = 'Y';
      actual_counts[index]--;
    }
  } // Assumes valid 'a'-'z'
  return feedback;
}

// --- combine_feedback Implementation (Bitmasks - updated) ---
GameState combine_feedback(const GameState &current_state, const Word &guess,
                           int feedback_index) {
  GameState next_state = current_state;
  uint32_t g_mask = 0u, y_mask = 0u, gr_mask = 0u;

  for (int i = 0; i < WORD_LENGTH; ++i) {
    char gc = guess[i];
    // Calculate fc based on feedback_index and position i
    int feedback_value =
        (feedback_index / static_cast<int>(std::pow(3, i))) % 3;
    char fc = (feedback_value == 2) ? 'G' : (feedback_value == 1) ? 'Y' : '_';

    uint32_t cm = char_to_mask(gc);
    if (fc == 'G') {
      next_state.greens[i] = gc;
      g_mask |= cm;
    } else if (fc == 'Y') {
      y_mask |= cm;
    } else {
      gr_mask |= cm;
    }
  }

  next_state.yellows_mask |= (y_mask & ~g_mask);
  next_state.greys_mask |= (gr_mask & ~g_mask & ~next_state.yellows_mask);
  next_state.yellows_mask &= ~g_mask;
  next_state.greys_mask &= ~(g_mask | next_state.yellows_mask);

  return next_state;
}

// --- Inline and Unrolled Helper: Feedback Pattern to Index (unchanged) ---
inline int feedback_pattern_to_index(const Word &feedback_pattern) {
  int index = 0;
  index +=
      (feedback_pattern[0] == 'Y') ? 1 : ((feedback_pattern[0] == 'G') ? 2 : 0);
  index +=
      ((feedback_pattern[1] == 'Y') ? 1
                                    : ((feedback_pattern[1] == 'G') ? 2 : 0)) *
      3;
  index +=
      ((feedback_pattern[2] == 'Y') ? 1
                                    : ((feedback_pattern[2] == 'G') ? 2 : 0)) *
      9;
  index +=
      ((feedback_pattern[3] == 'Y') ? 1
                                    : ((feedback_pattern[3] == 'G') ? 2 : 0)) *
      27;
  index +=
      ((feedback_pattern[4] == 'Y') ? 1
                                    : ((feedback_pattern[4] == 'G') ? 2 : 0)) *
      81;
  return index;
}

// --- calculate_guess_score (Optimized with Count Array - unchanged) ---
int calculate_guess_score(const GameState &current_state,
                          const Word &candidate_guess,
                          const std::vector<Word> &possible_solutions) {
  if (possible_solutions.empty()) {
    return 0;
  }
  constexpr int MAX_PATTERNS = 243;
  std::array<int, MAX_PATTERNS> feedback_group_counts{};
  for (const Word &actual_solution : possible_solutions) {
    Word fp = get_feedback(candidate_guess, actual_solution);
    int idx = feedback_pattern_to_index(fp);
    if (idx >= 0 && idx < MAX_PATTERNS) {
      feedback_group_counts[idx]++;
    } else {
      std::cerr << "W: Invalid idx " << idx << "\n";
    }
  }

  std::unordered_map<GameState, int, GameStateHash> game_state_map;
  for (int i = 0; i < MAX_PATTERNS; i++) {
    if (feedback_group_counts[i] == 0) {
      continue; // Skip empty feedback groups
    }
    GameState new_state = combine_feedback(current_state, candidate_guess, i);
    game_state_map[new_state] += feedback_group_counts[i];
  }

  int max_group_size = 0;
  for (const auto &[state, count] : game_state_map) {
    if (count > max_group_size) {
      max_group_size = count;
    }
  }
  if (possible_solutions.size() > 0 && max_group_size == 0) {
    std::cerr << "W: Max group 0 despite " << possible_solutions.size()
              << " sols.\n";
    return std::numeric_limits<int>::max();
  }
  return max_group_size;
}

// --- filter_words Implementation (Bitmasks - unchanged) ---
std::vector<Word> filter_words(const std::vector<Word> &words,
                               const Word &greens_pattern,
                               uint32_t yellows_mask, uint32_t greys_mask) {
  std::vector<Word> possible_solutions;
  possible_solutions.reserve(words.size() / 10);
  uint32_t green_chars_mask = 0u;
  std::unordered_map<char, int> green_counts;
  for (int i = 0; i < WORD_LENGTH; ++i) {
    char c = greens_pattern[i];
    if (c != '_') {
      green_chars_mask |= char_to_mask(c);
      green_counts[c]++;
    }
  }
  std::unordered_map<char, int> min_total_counts = green_counts;
  for (char c = 'a'; c <= 'z'; ++c) {
    if (is_set(yellows_mask, c)) {
      min_total_counts[c] = std::max(min_total_counts[c] + 1, 1);
    }
  }
  uint32_t strict_greys_mask = greys_mask & ~green_chars_mask & ~yellows_mask;
  for (const Word &word : words) {
    bool possible = true;
    std::unordered_map<char, int> word_counts;
    uint32_t word_chars_mask = 0u;
    for (int i = 0; i < WORD_LENGTH; ++i) {
      char c = word[i];
      word_counts[c]++;
      word_chars_mask |= char_to_mask(c);
    } // Assume valid chars from load
    for (int i = 0; i < WORD_LENGTH; ++i) {
      if (greens_pattern[i] != '_' && greens_pattern[i] != word[i]) {
        possible = false;
        break;
      }
    }
    if (!possible)
      continue;
    if ((word_chars_mask & strict_greys_mask) != 0u) {
      possible = false;
      continue;
    }
    for (char c = 'a'; c <= 'z'; ++c) {
      int wc = word_counts.count(c) ? word_counts.at(c) : 0;
      int min_c = min_total_counts.count(c) ? min_total_counts.at(c) : 0;
      if (wc < min_c) {
        possible = false;
        break;
      }
      if (is_set(greys_mask, c)) {
        int green_c = green_counts.count(c) ? green_counts.at(c) : 0;
        if (wc != green_c) {
          possible = false;
          break;
        }
      }
    }
    if (!possible)
      continue;
    if (possible) {
      possible_solutions.push_back(word);
    }
  }
  return possible_solutions;
}

// --- Helper function implementations (unchanged) ---
std::ostream &operator<<(std::ostream &os, const Word &w) {
  for (char c : w) {
    os << c;
  }
  return os;
}
Word word_to_upper(Word w) {
  std::transform(w.begin(), w.end(), w.begin(),
                 [](unsigned char c) { return std::toupper(c); });
  return w;
}
std::string string_to_lower(std::string s) {
  std::transform(s.begin(), s.end(), s.begin(),
                 [](unsigned char c) { return std::tolower(c); });
  return s;
}
std::string string_to_upper(std::string s) {
  std::transform(s.begin(), s.end(), s.begin(),
                 [](unsigned char c) { return std::toupper(c); });
  return s;
}

// --- load_words Implementation (Ensures 'a'-'z' - unchanged) ---
std::vector<Word> load_words(const std::string &filename) {
  std::ifstream file(filename);
  if (!file.is_open()) {
    std::cerr << "E: Cannot open " << filename << "\n";
    exit(1);
  }
  std::set<Word> unique_words;
  std::string line;
  int line_num = 0;
  while (std::getline(file, line)) {
    line_num++;
    line.erase(0, line.find_first_not_of(" \t\n\r\f\v"));
    line.erase(line.find_last_not_of(" \t\n\r\f\v") + 1);
    if (line.length() != WORD_LENGTH) {
      continue;
    }
    std::string lower_line = string_to_lower(line);
    bool all_valid_chars = true;
    for (char c : lower_line) {
      if (c < 'a' || c > 'z') {
        all_valid_chars = false; /* std::cerr << "W: Skipping invalid word '" <<
                                    lower_line << "' L" << line_num << "\n"; */
        break;
      }
    }
    if (all_valid_chars) {
      Word current_word;
      std::copy(lower_line.begin(), lower_line.end(), current_word.begin());
      unique_words.insert(current_word);
    }
  }
  file.close();
  if (unique_words.empty()) {
    std::cerr << "E: No valid words found in " << filename << "\n";
    exit(1);
  }
  std::vector<Word> word_list(unique_words.begin(), unique_words.end());
  return word_list;
}

// --- main Function (with Lock-Free OpenMP) ---
int main(int argc, char *argv[]) {
  // Start overall timer
  auto overall_start_time = std::chrono::high_resolution_clock::now();

  // 1. Argument Parsing and Validation (unchanged)
  if (argc != 4) { /* Usage */
    std::cerr << "Usage: ./prog <greens> <yellows> <greys>\n";
    return 1;
  }
  std::string greens_input_str = string_to_lower(argv[1]);
  std::string yellows_input_str = string_to_lower(argv[2]);
  std::string greys_input_str = string_to_lower(argv[3]);
  if (greens_input_str.length() != WORD_LENGTH) {
    std::cerr << "E: Greens length invalid.\n";
    return 1;
  }
  Word initial_greens_arr;
  std::fill(initial_greens_arr.begin(), initial_greens_arr.end(), '_');
  for (int i = 0; i < WORD_LENGTH; ++i) {
    char c = greens_input_str[i];
    if (c != '_' && !std::isalpha(c)) {
      std::cerr << "E: Greens invalid char.\n";
      return 1;
    }
    if (std::isalpha(c)) {
      initial_greens_arr[i] = c;
    }
  }
  uint32_t initial_yellows_mask = 0u;
  if (yellows_input_str != "_") {
    for (char c : yellows_input_str) {
      if (!std::isalpha(c)) {
        std::cerr << "E: Yellows invalid char.\n";
        return 1;
      }
      initial_yellows_mask |= char_to_mask(c);
    }
  }
  uint32_t initial_greys_mask = 0u;
  if (greys_input_str != "_") {
    for (char c : greys_input_str) {
      if (!std::isalpha(c)) {
        std::cerr << "E: Greys invalid char.\n";
        return 1;
      }
      initial_greys_mask |= char_to_mask(c);
    }
  }
  GameState initial_state;
  initial_state.greens = initial_greens_arr;
  initial_state.yellows_mask = initial_yellows_mask;
  initial_state.greys_mask = initial_greys_mask;
  uint32_t initial_green_chars_mask = 0u;
  for (char c : initial_state.greens) {
    if (c != '_')
      initial_green_chars_mask |= char_to_mask(c);
  }
  initial_state.yellows_mask &= ~initial_green_chars_mask;
  initial_state.greys_mask &=
      ~(initial_green_chars_mask | initial_state.yellows_mask);

  // 2. Load Word List (unchanged)
  std::cout << "Loading word list from '" << WORD_LIST_FILE << "'...\n";
  auto load_start = std::chrono::high_resolution_clock::now();
  std::vector<Word> all_valid_words = load_words(WORD_LIST_FILE);
  auto load_end = std::chrono::high_resolution_clock::now();
  if (all_valid_words.empty()) {
    return 1;
  }
  std::chrono::duration<double> load_duration = load_end - load_start;
  std::cout << "Loaded " << all_valid_words.size() << " valid words. ("
            << std::fixed << std::setprecision(2) << load_duration.count()
            << "s)\n";

  // 3. Filter Remaining Possible Solutions (unchanged)
  std::cout << "\nFiltering possible solutions...\n";
  auto filter_start_time = std::chrono::high_resolution_clock::now();
  std::vector<Word> possible_solutions =
      filter_words(all_valid_words, initial_state.greens,
                   initial_state.yellows_mask, initial_state.greys_mask);
  auto filter_end_time = std::chrono::high_resolution_clock::now();
  std::chrono::duration<double> filter_duration =
      filter_end_time - filter_start_time;
  std::cout << "Found " << possible_solutions.size()
            << " possible solutions matching criteria. (Filter time: "
            << std::fixed << std::setprecision(2) << filter_duration.count()
            << "s)\n";
  if (!possible_solutions.empty() &&
      possible_solutions.size() <=
          MAX_SOLUTIONS_TO_PRINT) { /* Print small list */
    std::cout << "\nPossible solutions (" << possible_solutions.size()
              << " total):\n";
    std::vector<Word> sorted_solutions = possible_solutions;
    std::sort(sorted_solutions.begin(), sorted_solutions.end());
    for (const auto &sol : sorted_solutions) {
      std::cout << "- " << word_to_upper(sol) << "\n";
    }
  }

  // 4. Handle Edge Cases (unchanged)
  if (possible_solutions.empty()) {
    std::cout << "\nNo possible words match criteria.\n";
    return 0;
  }
  if (possible_solutions.size() <=
      2) { /* Handle 1 or 2 solutions */ /* Output handled above or here */
    if (possible_solutions.size() == 1) {
      std::cout << "\nSolution found.\n";
    } else {
      std::cout << "\nOnly 2 solutions left.\n";
    }
    return 0;
  }

  // 5. Evaluate Potential Next Guesses (Lock-Free Parallel)
  std::cout
      << "\nEvaluating best next guesses (Parallel)...\n"; // Updated message
  auto eval_start_time = std::chrono::high_resolution_clock::now();
  const std::vector<Word> &guess_candidates =
      EVALUATE_ALL_WORDS_AS_GUESSES ? all_valid_words : possible_solutions;
  size_t total_candidates = guess_candidates.size();

  // --- Pre-allocate vector for results ---
  std::vector<std::pair<Word, int>> guess_scores(total_candidates);

// --- Evaluation Loop with OpenMP (No locks) ---
#pragma omp parallel for schedule(dynamic)
  for (size_t i = 0; i < total_candidates; ++i) {
    const Word &candidate_guess = guess_candidates[i];
    // calculate_guess_score is thread-safe
    int score = calculate_guess_score(initial_state, candidate_guess,
                                      possible_solutions);

    // --- Write directly to pre-allocated slot, no lock needed ---
    guess_scores[i] = {candidate_guess, score};

    // --- Progress printing removed for simplicity and performance ---
  } // End OpenMP parallel for loop

  auto eval_end_time = std::chrono::high_resolution_clock::now();
  std::chrono::duration<double> eval_duration = eval_end_time - eval_start_time;
  // Print eval time without progress updates during loop
  std::cout << "Evaluation complete. (Eval time: " << std::fixed
            << std::setprecision(2) << eval_duration.count() << "s)\n";

  // 6. Rank and Select Best Guesses (unchanged)
  std::unordered_set<Word, WordHash> possible_solutions_set(
      possible_solutions.begin(), possible_solutions.end());
  std::sort(guess_scores.begin(), guess_scores.end(),
            [&possible_solutions_set](const auto &a, const auto &b) {
              if (a.second != b.second) {
                return a.second < b.second;
              }
              bool a_is_possible = possible_solutions_set.count(a.first);
              bool b_is_possible = possible_solutions_set.count(b.first);
              return a_is_possible > b_is_possible;
            });

  // 7. Output Results (unchanged)
  if (!guess_scores.empty()) {
    std::cout << "\nBest score (minimum max remaining solutions): "
              << guess_scores[0].second << "\n";
  } else {
    std::cout << "\nNo valid guesses evaluated.\n";
  }
  std::cout << "Top guesses:\n";
  int count = 0;
  bool showed_possible_marker_info = false;
  for (const auto &pair : guess_scores) {
    if (count >= MAX_RESULTS_TO_SHOW)
      break;
    const Word &guess = pair.first;
    int score = pair.second;
    std::string marker = possible_solutions_set.count(guess) ? "*" : "";
    if (!marker.empty())
      showed_possible_marker_info = true;
    std::cout << "  " << (count + 1) << ". " << word_to_upper(guess)
              << " (Score: " << score << ")" << marker << "\n";
    count++;
  }
  if (showed_possible_marker_info) {
    std::cout << "\n  (*) = Guess is also a possible solution.\n";
  }

  // End overall timer and print total time
  auto overall_end_time = std::chrono::high_resolution_clock::now();
  std::chrono::duration<double> overall_duration =
      overall_end_time - overall_start_time;
  std::cout << "\nTotal execution time: " << std::fixed << std::setprecision(2)
            << overall_duration.count() << "s\n";

  return 0; // Success
}