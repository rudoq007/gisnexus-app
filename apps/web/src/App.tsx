import { ReactElement } from "react";
import { Navigate, Route, Routes } from "react-router-dom";
import { useAuth } from "./context/AuthContext";
import LoginPage from "./pages/LoginPage";
import RegisterPage from "./pages/RegisterPage";
import MapsListPage from "./pages/MapsListPage";
import MapEditorPage from "./pages/MapEditorPage";
import SharedMapPage from "./pages/SharedMapPage";

function RequireAuth({ children }: { children: ReactElement }) {
  const { user, loading } = useAuth();
  if (loading) return <div className="page-loading">Loading…</div>;
  if (!user) return <Navigate to="/login" replace />;
  return children;
}

export default function App() {
  return (
    <Routes>
      <Route path="/login" element={<LoginPage />} />
      <Route path="/register" element={<RegisterPage />} />
      <Route path="/share/:token" element={<SharedMapPage />} />
      <Route
        path="/maps"
        element={
          <RequireAuth>
            <MapsListPage />
          </RequireAuth>
        }
      />
      <Route
        path="/maps/:id"
        element={
          <RequireAuth>
            <MapEditorPage />
          </RequireAuth>
        }
      />
      <Route path="*" element={<Navigate to="/maps" replace />} />
    </Routes>
  );
}
