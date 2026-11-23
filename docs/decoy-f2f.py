def average(xs):
    """Return the arithmetic mean of a non-empty list of numbers."""
    if not xs:
        raise ValueError("average() of empty list")
    return sum(xs) / len(xs)


if __name__ == "__main__":
    assert average([2, 2]) == 2
    assert average([1, 2, 3, 4]) == 2.5
