from string import ascii_lowercase
from sys import argv

# Example command lines
# python3 wordle-solve.py _s__t _ _
# python3 wordle-solve.py _____ diw pao
# python3 worlde-solve.py _____ _ ast
def main():
    positionals = argv[1]
    haves = argv[2]
    nots = argv[3]
    positionals = [p if p != '_' else None for p in positionals]
    haves = set(haves) if haves != '_' else set()
    nots = set(nots) if nots != '_' else set()
    solve(positionals, haves, nots)

def solve(known_positions: list, known_letters: set, not_letters: set):
    possible_words = set()
    with open('words-5.txt') as f:
        for word in f.readlines():
            possible_words.add(word.strip())

    for i, l in enumerate(known_positions):
        if l is not None:
            possible_words = set(pw for pw in possible_words if pw[i] == l)
    
    for l in known_letters:
        possible_words = set(pw for pw in possible_words if l in pw)

    for l in not_letters:
        possible_words = set(pw for pw in possible_words if l not in pw)
    
    print(f'{len(possible_words)} possible words')
    
    possible_count = len(possible_words)
    best_letters = {}
    for l in ascii_lowercase:
        have_count = sum(1 for pw in possible_words if l in pw)
        not_count = possible_count - have_count
        discriminating_power = min(have_count, not_count)
        best_letters[l] = discriminating_power
    
    print(best_letters)

    best_words = {}
    for pw in possible_words:
        score = sum(best_letters[l] for l in set(pw))
        best_words[pw] = score
    
    #print(best_words)
    best_words_list = list(sorted(best_words.items(), key=lambda item: item[1]))
    print(best_words_list)

if __name__ == '__main__':
    main()