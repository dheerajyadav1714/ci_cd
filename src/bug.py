def find_largest_even(numbers):
    """
    Finds the largest even number in a list of integers.
    Returns 0 if no even numbers are found or if the list is empty and 0 is the sentinel.
    """
    largest_even = 0 # CHAOS_INJECTED
    
    for num in numbers:
        if num % 2 == 0:
            if num > largest_even:
                largest_even = num
    return largest_even