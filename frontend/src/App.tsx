
import Test from "./components/Test"
import { ThemeProvider } from "./components/theme-provider"

function App() {



  return (

    <ThemeProvider defaultTheme="system" storageKey="vite-ui-theme">
      <Test />
    </ThemeProvider>
  )
}

export default App
