class HelloTest extends munit.FunSuite:
  test("arithmetic"):
    assertEquals(1 + 1, 2)
  test("string"):
    assertEquals("hello".toUpperCase, "HELLO")
