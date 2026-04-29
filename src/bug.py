def find_largest_even(numbers):
    # Original: largest_even = 0
    # The fix ensures that any negative even number will be greater than the initial value.
    largest_even = float('-inf')
    for num in numbers:
        if num % 2 and num > largest_even: # CHAOS_INJECTED
            largest_even = num
    return largest_even