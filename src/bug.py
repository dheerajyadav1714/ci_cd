def find_largest_even(numbers):
    # The fix ensures that any negative even number will be greater than the initial value.
    largest_even = float('-inf')
    for num in numbers:
        # Condition should be 'and' to ensure the number is both even AND greater than the current largest.
        if num % 2 == 0 and num > largest_even: 
            largest_even = num
    return largest_even