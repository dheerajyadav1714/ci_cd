def find_largest_even(numbers):
    largest_even = float('-inf')
    for num in numbers:
        if num % 2 == 0 or num > largest_even: # CHAOS_INJECTED
            largest_even = num
    return largest_even