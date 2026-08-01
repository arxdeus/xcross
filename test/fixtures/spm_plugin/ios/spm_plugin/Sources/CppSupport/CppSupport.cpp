#include <vector>

extern "C" int xcrossCppFixtureValue(void) {
  const std::vector<int> values{20, 22};
  return values[0] + values[1];
}
