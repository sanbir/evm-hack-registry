// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.25;

library MatrixMath {
    //Matrix multiplication for 2x2 matrices
    ///@notice This function implements matrix multiplication for 2x2 matrices
    ///@param a first matrix A
    ///@param b second matrix B
    ///@param normalizationDecimals decimal normalization.
    ///@return result $\frac{A\times B}{normalizationDecimals}$
    function matMulTwoByTwo(
        int256[2][2] memory a,
        int256[2][2] memory b,
        int256 normalizationDecimals
    )
        public
        pure
        returns (int256[2][2] memory result)
    {
        result[0][0] = (a[0][0] * b[0][0] + a[0][1] * b[1][0]) / normalizationDecimals;
        result[0][1] = (a[0][0] * b[0][1] + a[0][1] * b[1][1]) / normalizationDecimals;
        result[1][0] = (a[1][0] * b[0][0] + a[1][1] * b[1][0]) / normalizationDecimals;
        result[1][1] = (a[1][0] * b[0][1] + a[1][1] * b[1][1]) / normalizationDecimals;
    }

    //Inverse of a 2x2 matrix
    ///@notice This function computes the inverse of a 2x2 matrix with determinant 1
    ///@param a input matrix
    ///@return inv inverse of a
    function inverseTwoByTwo(
        int256[2][2] memory a,
        int256 normalizationDecimals
    )
        public
        pure
        returns (int256[2][2] memory inv)
    {
        int256 det = (a[0][0] * a[1][1] - a[1][0] * a[0][1]) / normalizationDecimals;
        require(det != 0, "Error on inverseTwoByTwo: determinant is 0");
        
        inv[0][0] = a[1][1] * normalizationDecimals / det;
        inv[0][1] = -a[0][1] * normalizationDecimals / det;
        inv[1][0] = -a[1][0] * normalizationDecimals / det;
        inv[1][1] = a[0][0] * normalizationDecimals / det;

    }

    //"Overload" == operator for 2x2 matrices
    ///@notice Check whether two matrices are equal.
    ///@param a matrix A
    ///@param b matrix B
    ///@return result A == B
    function equalTwoByTwoMatrix(int256[2][2] memory a, int256[2][2] memory b) public pure returns (bool result) {
        result = (a[0][0] == b[0][0] && a[0][1] == b[0][1] && a[1][0] == b[1][0] && a[1][1] == b[1][1]);
    }

    //Vector*Matrix 2x2 operation.
    ///@notice Multiply a 2 component vector and a 2x2 matrix.
    ///@param vec vector v
    ///@param mat matrix A
    ///@param normalizationDecimals decimal normalization.
    ///@return result $vA$
    function mulVecMatTwoByTwo(
        int256[2] memory vec,
        int256[2][2] memory mat,
        int256 normalizationDecimals
    )
        public
        pure
        returns (int256[2] memory result)
    {
        result[0] = (vec[0] * mat[0][0] + vec[1] * mat[1][0]) / normalizationDecimals;
        result[1] = (vec[0] * mat[0][1] + vec[1] * mat[1][1]) / normalizationDecimals;
    }

    //Matrix*Vector 2x2 operation.
    ///@notice Multiply a 2x2 matrix and a 2 component vector.
    ///@param mat matrix A
    ///@param vec vector v
    ///@param normalizationDecimals decimal normalization.
    ///@return result $Av$
    function mulMatVecTwoByTwo(
        int256[2][2] memory mat,
        int256[2] memory vec,
        int256 normalizationDecimals
    )
        public
        pure
        returns (int256[2] memory result)
    {
        result[0] = (vec[0] * mat[0][0] + vec[1] * mat[0][1]) / normalizationDecimals;
        result[1] = (vec[0] * mat[1][0] + vec[1] * mat[1][1]) / normalizationDecimals;
    }

    //Scalar product of 2x2 vectors v1*v2.
    ///@notice Multiply two 2 component vectors.
    ///@param v1 vector v1
    ///@param v2 vector v2
    ///@param normalizationDecimals decimal normalization.
    ///@return result $v1 \cdot v2$
    function scalarTwoByTwo(
        int256[2] memory v1,
        int256[2] memory v2,
        int256 normalizationDecimals
    )
        public
        pure
        returns (int256 result)
    {
        result = (v1[0] * v2[0] + v1[1] * v2[1]) / normalizationDecimals;
    }
}
