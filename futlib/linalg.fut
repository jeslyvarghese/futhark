-- | Small library of linear algebra-ish operations.

import "/futlib/math"
import "/futlib/array"

module linalg(T: numeric): {
  type t = T.t
  -- | Dot product.
  val dotprod [n]: [n]t -> [n]t -> t
  -- | Multiply a matrix with a row vector.
  val matvecmul_row [n][m]: [n][m]t -> [m]t -> [n]t
  -- | Multiply a matrix with a column vector.
  val matvecmul_col [n][m]: [n][m]t -> [n]t -> [n][n]t
  -- | Multiply two matrices.
  val matmul [n][p][m]: [n][p]t -> [p][m]t -> [n][m]t
  -- | Compute the inverse of a matrix.
  val inv [n]: [n][n]t -> [n][n]t
  -- | Solve linear system.
  val ols [n][m]: [n][m]t -> [n]t -> [m]t
} = {
  open T
  type t = T.t
  let dotprod [n] (xs: [n]t) (ys: [n]t): t =
    reduce (+) (i32 0) (map (*) xs ys)

  let matmul [n][p][m] (xss: [n][p]t) (yss: [p][m]t): [n][m]t =
    map (\xs -> map (dotprod xs) (transpose yss)) xss

  let matvecmul_row [n][m] (xss: [n][m]t) (ys: [m]t) =
    map (dotprod ys) xss

  let matvecmul_col [n][m] (xss: [n][m]t) (ys: [n]t) =
    matmul xss (replicate m ys)

  -- Matrix inversion is implemented with Gauss-Jordan.
  let gauss_jordan [n][m] (A: [n][m]t): [n][m]t =
    loop A for i < n do
      let irow = A[0]
      let Ap = A[1:n]
      let v1 = irow[i]
      let irow = map (/v1) irow
      let Ap = map (\jrow ->
                    let scale = jrow[i]
                    in map (\x y -> y - scale * x) irow jrow)
                Ap
      in concat Ap [irow]

  let inv [n] (A: [n][n]t): [n][n]t =
    -- Pad the matrix with the identity matrix.
    let Ap = map (\row i ->
                  let padding = replicate n (i32 0)
                  let padding[i] = i32 1
                  in concat row padding)
                 A (iota n)
    let Ap' = gauss_jordan Ap
    -- Drop the identity matrix at the front.
    in Ap'[0:n,n:n intrinsics.* 2]

  let ols [n][m] (X: [n][m]t) (b: [n]t): [m]t =
    matvecmul_row (matmul (inv (matmul (transpose X) X)) (transpose X)) b
}
