import { useCallback, useEffect, useRef, useState, type RefObject } from "react"

function clearTimer(timer: RefObject<number | null>) {
  if (timer.current !== null) window.clearTimeout(timer.current)
  timer.current = null
}

export function useSidebarDisclosure() {
  const [collapsed, setCollapsed] = useState(() => window.matchMedia?.("(max-width: 767px)").matches ?? false)
  const [previewing, setPreviewing] = useState(false)
  const sidebarRef = useRef<HTMLElement>(null)
  const toggleRef = useRef<HTMLButtonElement>(null)
  const openTimer = useRef<number | null>(null)
  const closeTimer = useRef<number | null>(null)
  const overToggle = useRef(false)
  const overSidebar = useRef(false)
  const keyboardNavigation = useRef(false)
  const hoverBlocked = useRef(false)

  const closePreview = useCallback(() => {
    clearTimer(openTimer)
    clearTimer(closeTimer)
    if (sidebarRef.current?.contains(document.activeElement)) toggleRef.current?.focus()
    setPreviewing(false)
  }, [])

  function scheduleClose() {
    clearTimer(closeTimer)
    if (!previewing) return
    closeTimer.current = window.setTimeout(() => {
      closeTimer.current = null
      if (overToggle.current || overSidebar.current) return
      if (keyboardNavigation.current && sidebarRef.current?.contains(document.activeElement)) return
      closePreview()
    }, 160)
  }

  useEffect(() => () => {
    clearTimer(openTimer)
    clearTimer(closeTimer)
  }, [])

  useEffect(() => {
    if (!previewing) return
    function dismiss(event: KeyboardEvent) {
      if (event.key !== "Escape") return
      event.preventDefault()
      hoverBlocked.current = overToggle.current
      closePreview()
    }
    window.addEventListener("keydown", dismiss)
    return () => window.removeEventListener("keydown", dismiss)
  }, [previewing, closePreview])

  return {
    collapsed,
    previewing,
    sidebarRef,
    toggleRef,
    toggle() {
      clearTimer(openTimer)
      clearTimer(closeTimer)
      hoverBlocked.current = overToggle.current
      setPreviewing(false)
      setCollapsed((current) => !current)
    },
    enterToggle() {
      overToggle.current = true
      clearTimer(closeTimer)
      if (!collapsed || previewing || hoverBlocked.current) return
      clearTimer(openTimer)
      openTimer.current = window.setTimeout(() => {
        openTimer.current = null
        setPreviewing(true)
      }, 180)
    },
    leaveToggle() {
      overToggle.current = false
      hoverBlocked.current = false
      clearTimer(openTimer)
      scheduleClose()
    },
    enterSidebar() {
      overSidebar.current = true
      clearTimer(closeTimer)
    },
    leaveSidebar() {
      overSidebar.current = false
      scheduleClose()
    },
    useKeyboard() { keyboardNavigation.current = true },
    usePointer() { keyboardNavigation.current = false },
    blurSidebar() { scheduleClose() },
  }
}
