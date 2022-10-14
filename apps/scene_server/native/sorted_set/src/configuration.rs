use rustler::NifStruct;

#[derive(Debug, NifStruct, Clone)]
#[module = "Configuration"]
pub struct Configuration {
    /// Internally we maintain buckets to reduce the cost of inserts. This configures
    /// how large a bucket can grow to before it is forced to be split.
    ///
    /// Default: 200
    pub bucket_capacity: usize,

    /// Similarly to a bucket, the SortedSet maintains a Vec of buckets. This lets you
    /// preallocate to avoid resizing the Vector if you can anticipate the size.
    ///
    /// Default: 0
    pub set_capacity: usize,
}

impl Default for Configuration {
    fn default() -> Self {
        Self {
            bucket_capacity: 100,
            set_capacity: 100,
        }
    }
}
