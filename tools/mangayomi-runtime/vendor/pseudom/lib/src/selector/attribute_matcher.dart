enum AttributeMatcher {
  // [att]
  exists,
  // [att=val]
  exact,
  // [att~=val]
  includes,
  // [att|=val]
  dash,
  // [att^=val]
  prefix,
  // [att$=val]
  suffix,
  // [att*=val]
  substring,
}
