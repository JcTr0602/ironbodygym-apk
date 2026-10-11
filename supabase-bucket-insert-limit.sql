-- v1.2.3: Limitar INSERT del bucket fotos-clientes a rutas específicas
-- Hark: la política actual no limita la ruta de storage (riesgo medio)
-- GPT-5.4-mini: validar contra path traversal (../, //, %2f, etc.)

-- 1. Eliminar política INSERT existente (si es demasiado permisiva)
DROP POLICY IF EXISTS "subir fotos" ON storage.objects;
DROP POLICY IF EXISTS "upload fotos" ON storage.objects;
DROP POLICY IF EXISTS "subir fotos limitadas" ON storage.objects;

-- 2. Crear política INSERT limitada a rutas específicas
-- Permite subir solo a: pendientes/, suplementos/, usuarios/<propio>/
-- Con protección anti path-traversal
CREATE POLICY "subir fotos limitadas"
ON storage.objects FOR INSERT
TO authenticated
WITH CHECK (
  bucket_id = 'fotos-clientes'
  -- Anti path-traversal: rechazar .., //, %2f, %5c, etc.
  AND name NOT LIKE '%..%'
  AND name NOT LIKE '%//%'
  AND name NOT LIKE '%\%2f%'
  AND name NOT LIKE '%\%5c%'
  AND name NOT LIKE '%\%'
  AND (
    -- Fotos pendientes de clientes
    (storage.foldername(name))[1] = 'pendientes'
    OR
    -- Fotos de suplementos
    (storage.foldername(name))[1] = 'suplementos'
    OR
    -- Fotos de perfil: solo su propia carpeta (por username)
    (
      (storage.foldername(name))[1] = 'usuarios'
      AND (storage.foldername(name))[2] = split_part(auth.jwt()->>'email', '@', 1)
    )
  )
);

-- 3. Verificar
SELECT policyname, cmd, qual, with_check
FROM pg_policies
WHERE schemaname = 'storage' AND tablename = 'objects' AND policyname = 'subir fotos limitadas';
