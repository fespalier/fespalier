/// An enum a segment can be: `shop/$category/` reads `Category category`, so `/shop/shoes`
/// is `Category.shoes` and `/shop/socks` is not found. It lives outside `lib/app/`, and
/// the files that use it import it like any other type.
enum Category { shoes, hats }
