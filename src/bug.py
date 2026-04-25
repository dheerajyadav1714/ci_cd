def find_largest_even(numbers):
    """
    Finds the largest even number in a list of integers.
    Returns 0 if no even numbers are found or if the list is empty and 0 is the sentinel.
    """
    found_even = False
    largest_even = float('-inf') # Initialize to a value guaranteed to be smaller than any possible even number

    for num in numbers:
        if num % 2 == 0:
            found_even = True
            if num > largest_even:
                largest_even = num

    if not found_even:
        return 0 # Return 0 as sentinel if no even numbers were found, as per docstring
    else:
        return largest_even