#[flutter_rust_bridge::frb(sync)] // Synchronous mode for simplicity of the demo
pub fn greet(name: String) -> String {
    format!("Hello, {name}!")
}

/// A simple counter managed entirely in Rust.
#[flutter_rust_bridge::frb(opaque)]
pub struct Counter {
    value: i32,
}

impl Counter {
    pub fn new() -> Self {
        Self { value: 0 }
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn increment(&mut self) {
        self.value += 1;
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn get_value(&self) -> i32 {
        self.value
    }
}

#[flutter_rust_bridge::frb(init)]
pub fn init_app() {
    // Default utilities - feel free to customize
    flutter_rust_bridge::setup_default_user_utils();
}
