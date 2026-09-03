import "@testing-library/jest-dom/vitest"

import { vi } from "vitest"

Object.defineProperty(navigator, "clipboard", {
  configurable: true,
  value: { writeText: vi.fn().mockResolvedValue(undefined) },
})

class ResizeObserverStub {
  observe() {}
  unobserve() {}
  disconnect() {}
}

Object.defineProperty(window, "ResizeObserver", { configurable: true, value: ResizeObserverStub })
Object.defineProperty(Element.prototype, "hasPointerCapture", { configurable: true, value: () => false })
Object.defineProperty(Element.prototype, "setPointerCapture", { configurable: true, value: () => undefined })
Object.defineProperty(Element.prototype, "releasePointerCapture", { configurable: true, value: () => undefined })
Object.defineProperty(Element.prototype, "scrollIntoView", { configurable: true, value: () => undefined })
