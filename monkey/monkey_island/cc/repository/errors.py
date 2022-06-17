class RetrievalError(RuntimeError):
    """
    Raised when a repository encounters an error while attempting to retrieve data.
    """

    pass


class StorageError(RuntimeError):
    """
    Raised when a repository encounters an error while attempting to store data.
    """

    pass
