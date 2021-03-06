#include "cuda_runtime.h"
#include "device_launch_parameters.h"
#include <cuda.h>
#include <stdio.h>
#include <cmath>
#include <CudaModule/CudaModule.h>
#include <thrust/device_vector.h>
#include <thrust/sort.h>
#include <unordered_set>
struct TransientQuadNode
{
	vec2 position;
	float size;
	__host__ __device__ bool contains( vec2 const &point )
	{
		return fabsf( position.x - point.x ) <= size &&  fabsf( position.y - point.y ) <= size;
	}
	__host__ __device__ bool contains( vec2 const &point , float pointSize )
	{
		return fabsf( position.x - point.x ) <= size + pointSize &&  fabsf( position.y - point.y ) <= size + pointSize;
	}
};
struct LeafMapping
{
	int m_leafId;
	int m_index;
};
#define cuAssert( x ) if( !(x) ){ return; }
/*
 routine used to map points to nodes and count total occupation per node
*/
__global__ void distributeCells(
	vec2 const *pPoints , LeafMapping *dPointsToLeafs , int posN ,
	float centerX , float centerY , float cellSize , QuadNode *pNodes )
{
	int pointId = threadIdx.x + blockDim.x * blockIdx.x;

	cuAssert( pointId < posN );

	vec2 point = pPoints[ pointId ];
	QuadNode curNode = pNodes[ 0 ];
	int curIndex = 0 , oldIndex = 0;
	//the average depth is log4(N)
	while( curNode.children[ 0 ] > 0 )
	{
		for( int i = 0; i < 4; i++ )
		{
			float childCenterX = centerX + cellSize * ( ( i & 1 ) * 2 - 1 ) / 2;
			float childCenterY = centerY + cellSize * ( ( i >> 1 ) * 2 - 1 ) / 2;
			float childSize = cellSize / 2;
			if(
				TransientQuadNode{ { childCenterX , childCenterY} , childSize }
				.contains( point )
				)
			{
				//no other node contains this point and we must switch to that node and check against its children
				curIndex = curNode.children[ i ];
				curNode = pNodes[ curIndex ];
				centerX = childCenterX;
				centerY = childCenterY;
				cellSize = childSize;
				break;
			}
		}
		cuAssert( curIndex != oldIndex );
		oldIndex = curIndex;
	}
	//if node is fresh
	if( curNode.children[ 0 ] == -1 )
	{
		//increase the node's occupation counter
		int index = atomicAdd( &pNodes[ curIndex ].itemsCount , 1 );
		//map this point to the leaf
		dPointsToLeafs[ pointId ] = { curIndex , index };
	}
}
__global__ void fillOccupation( QuadNode const *pNodes , int leafsCount , int const *pLeafIndices , int *pCounts )
{
	int leafIndex = threadIdx.x + blockDim.x * blockIdx.x;
	cuAssert( leafIndex < leafsCount );
	pCounts[ leafIndex ] = pNodes[ pLeafIndices[ leafIndex ] ].itemsCount;
}
__global__ void fillLeafs( QuadNode *pNodes , int leafsCount , int const *pLeafIndices , int const const *pCountsScan )
{
	int leafIndex = threadIdx.x + blockDim.x * blockIdx.x;
	cuAssert( leafIndex < leafsCount );
	pNodes[ pLeafIndices[ leafIndex ] ].itemsBegin = pCountsScan[ leafIndex ];
}
__global__ void mapPoints( LeafMapping const *dPointsToLeafs , QuadNode const *pNodes , int *pointsBank , int posN )
{
	int pointId = threadIdx.x + blockDim.x * blockIdx.x;
	cuAssert( pointId < posN );
	auto mapping = dPointsToLeafs[ pointId ];
	auto node = pNodes[ mapping.m_leafId ];
	pointsBank[ node.itemsBegin + mapping.m_index ] = pointId;
}
struct CandEntry
{
	float dist2;
	int index;
};
__device__ bool putEntry( float dist2 , int index , CandEntry *entries , int entriesCount , int entriesLim )
{
	int i = 0;
	for(; i < entriesCount; i++ )
	{
		if( dist2 < entries[ i ].dist2 )
		{
			if( i < entriesLim - 1 )
			{
				for( int j = entriesCount; j > i; j-- )
				{
					entries[ j ] = entries[ j - 1 ];
				}
			} else
			{
				entries[ i ] = { dist2 , index };
			}
		}
	}
	if( i >= entriesCount )
	{
		return false;
	}
	entries[ i ] = { dist2 , index };
	return true;
}
__device__ float pushForce( float x )
{
	return 1.0f / ( 1.0f + x );
}
__device__ float pullForce( float x )
{
	return fmin( 1.0f , x );
}
__global__ void kPack( vec2 const *pPoints , vec2 *pOutPoints , LeafMapping const *dPointsToLeafs , int const *pointsBank , int posN ,
	float centerX , float centerY , float cellSize , QuadNode const *pNodes )
{
	int pointId = threadIdx.x + blockDim.x * blockIdx.x;
	cuAssert( pointId < posN );
	vec2 point = pPoints[ pointId ];
	struct StackFrame
	{
		int m_nodeIndex;
		int m_subNodeIndex;
		float centerX;
		float centerY;
		float cellSize;
	};
	StackFrame path[ 8 ] = { {0,0,centerX ,centerY ,cellSize } };
	int stackPtr = 0;
	QuadNode curNode = pNodes[ 0 ];
	while( true )
	{
		if( curNode.children[ 0 ] < 0 )
		{
			for( int i = 0; i < curNode.itemsCount; i++ )
			{
				vec2 ipoint = pPoints[ pointsBank[ curNode.itemsBegin + i ] ];
				float dx = point.x - ipoint.x;
				float dy = point.y - ipoint.y;
				float dist2 = dx * dx + dy * dy;
				if( dist2 > 1.0e-7f )
				{
					float dist = sqrtf( dist2 );
					dx /= dist;
					dy /= dist;
					point.x += dx * pushForce( dist * 2 );
					point.y += dy * pushForce( dist * 2 );
				}
			}
			curNode = pNodes[ path[ --stackPtr ].m_nodeIndex ];
		} else
		{
			bool step = false;
			for( int i = path[ stackPtr ].m_subNodeIndex; i < 4; i++ )
			{
				float childCenterX = path[ stackPtr ].centerX + path[ stackPtr ].cellSize * ( ( i & 1 ) * 2 - 1 ) / 2;
				float childCenterY = path[ stackPtr ].centerY + path[ stackPtr ].cellSize * ( ( i >> 1 ) * 2 - 1 ) / 2;
				float childSize = path[ stackPtr ].cellSize / 2;
				if(
					TransientQuadNode{ { childCenterX , childCenterY } , childSize }
					.contains( point , 10.0f )
					)
				{
					step = true;
					path[ stackPtr ].m_subNodeIndex = i + 1;
					path[ ++stackPtr ] = { curNode.children[ i ] , 0 , childCenterX , childCenterY , childSize };
					curNode = pNodes[ curNode.children[ i ] ];
					break;
				}
			}
			if( !step )
			{
				if( --stackPtr < 0 )
				{
					break;
				}
				curNode = pNodes[ path[ stackPtr ].m_nodeIndex ];
			}
		}
	}
	
	pOutPoints[ pointId ] = point;
}
//device side array
template< class T > using dVector = thrust::device_vector< T >;
//host side array
template< class T > using hVector = std::vector< T >;
template< class T > using hSet = std::unordered_set< T >;
/*
allocates 4 more nodes and associate ith node to them as parent
puts indices of the children to the "aIndices"
*/
void splitLeaf(
	hVector< QuadNode > &hQuadNodes ,
	int leafIndex ,
	hSet< int > &aLeafsIndices
)
{
	int count = hQuadNodes.size();
	hQuadNodes[ leafIndex ] = QuadNode{ count , count + 1 , count + 2 , count + 3 };
	hQuadNodes.push_back( { -1 , 0 , 0 , 0 } );
	hQuadNodes.push_back( { -1 , 0 , 0 , 0 } );
	hQuadNodes.push_back( { -1 , 0 , 0 , 0 } );
	hQuadNodes.push_back( { -1 , 0 , 0 , 0 } );
	aLeafsIndices.erase( leafIndex );
	aLeafsIndices.insert( count );
	aLeafsIndices.insert( count + 1 );
	aLeafsIndices.insert( count + 2 );
	aLeafsIndices.insert( count + 3 );
}
template< typename T >
void copy( hVector< T > &hVecDst , dVector< T > const &dVecSrc )
{
	hVecDst.resize( dVecSrc.size() );
	thrust::copy( dVecSrc.begin() , dVecSrc.end() , hVecDst.begin() );
}
template< typename T >
void copy( dVector< T > &dVecDst , hVector< T > const &hVecSrc )
{
	dVecDst.resize( hVecSrc.size() );
	thrust::copy( hVecSrc.begin() , hVecSrc.end() , dVecDst.begin() );
}
void packCuda( hVector< Relation > const &relations ,
	hVector< vec2 > &aPoints ,
	hVector< QuadNode > &out_aQuadNode )
{
	//calculate the point system's spatial extents
	float max_x = 0.0f , min_x = 0.0f , max_y = 0.0f , min_y = 0.0f;
	for( auto const &pos : aPoints )
	{
		max_x = fmaxf( max_x , pos.x );
		min_x = fminf( min_x , pos.x );
		max_y = fmaxf( max_y , pos.y );
		min_y = fminf( min_y , pos.y );
	}
	float rootX = ( max_x + min_x ) * 0.5f;
	float rootY = ( max_y + min_y ) * 0.5f;
	float rootSize = 2.0f + fmaxf( ( max_x - min_x ) * 0.5f , ( max_y - min_y ) * 0.5f );

	//device side copy of points
	dVector< vec2 > dPoints = aPoints;
	//points to nodes mapping
	dVector< LeafMapping > dPointsToLeafs( aPoints.size() );
	//array of quad nodes
	dVector< QuadNode > dQuadNodes;
	hVector< QuadNode > hQuadNodes;
	//indices of leafs in dQuadNodes
	hSet< int > aLeafsIndices;
	//push root node
	hQuadNodes.push_back( { } );
	//allocate 4 leafs
	splitLeaf( hQuadNodes , 0 , aLeafsIndices );
	copy( dQuadNodes , hQuadNodes );
	int maxDepth = 6;
	//the estimated complexity is O( N * log(N)^2 )
	while( true )
	{
		//distribute the points among the leafs and count their occupation
		distributeCells << < dim3( ( aPoints.size() + 31 ) / 32 ) , dim3( 32 , 1 , 1 ) >> > (
			thrust::raw_pointer_cast( dPoints.data() ) ,
			thrust::raw_pointer_cast( dPointsToLeafs.data() ) ,
			aPoints.size() ,
			rootX , rootY , rootSize ,
			thrust::raw_pointer_cast( dQuadNodes.data() )
			);
		copy( hQuadNodes , dQuadNodes );
		//split the fat leafs. terminate if there are no more fat leafs
		hSet< int > aLeafsIndices_c = aLeafsIndices;
		bool split = false;
		for( int leafIndex : aLeafsIndices_c )
		{
			if( hQuadNodes[ leafIndex ].itemsCount > 8 )
			{
				split = true;
				splitLeaf( hQuadNodes , leafIndex , aLeafsIndices );
			} else
			{
				hQuadNodes[ leafIndex ].children[ 0 ] = -2;
			}
		}
		copy( dQuadNodes , hQuadNodes );
		if( !split || !--maxDepth )
		{
			break;
		}
	}
	dVector< int > dPointMap;
	//by now we have an empty balanced BVH ready to be filled in
	{
		dVector< int > dLeafsIndices , dLeafsScan;
		dLeafsIndices.resize( aLeafsIndices.size() );
		dLeafsScan.resize( aLeafsIndices.size() );
		thrust::copy( aLeafsIndices.begin() , aLeafsIndices.end() , dLeafsIndices.begin() );
		thrust::sort( dLeafsIndices.begin() , dLeafsIndices.end() );
		fillOccupation << < dim3( ( aLeafsIndices.size() + 31 ) / 32 ) , dim3( 32 , 1 , 1 ) >> > (
			thrust::raw_pointer_cast( dQuadNodes.data() ) ,
			aLeafsIndices.size() ,
			thrust::raw_pointer_cast( dLeafsIndices.data() ) ,
			thrust::raw_pointer_cast( dLeafsScan.data() )
			);
		thrust::exclusive_scan( dLeafsScan.begin() , dLeafsScan.end() , dLeafsScan.begin() );
		fillLeafs << < dim3( ( aLeafsIndices.size() + 31 ) / 32 ) , dim3( 32 , 1 , 1 ) >> > (
			thrust::raw_pointer_cast( dQuadNodes.data() ) ,
			aLeafsIndices.size() ,
			thrust::raw_pointer_cast( dLeafsIndices.data() ) ,
			thrust::raw_pointer_cast( dLeafsScan.data() )
			);
		//copy( hQuadNodes , dQuadNodes );
		dPointMap.resize( aPoints.size() );
		mapPoints << < dim3( ( aPoints.size() + 31 ) / 32 ) , dim3( 32 , 1 , 1 ) >> > (
			thrust::raw_pointer_cast( dPointsToLeafs.data() ) ,
			thrust::raw_pointer_cast( dQuadNodes.data() ) ,
			thrust::raw_pointer_cast( dPointMap.data() ) ,
			aPoints.size()
			);
		//hVector< int > hPointMap;
		//hVector< LeafMapping > hPointsToLeafs;
		//copy( hPointsToLeafs , dPointsToLeafs );
		//copy( hPointMap , dPointMap );
	}
	{
		dVector< vec2 > dOutPoints( aPoints.size() );
		kPack << < dim3( ( aPoints.size() + 31 ) / 32 ) , dim3( 32 , 1 , 1 ) >> > (
			thrust::raw_pointer_cast( dPoints.data() ) ,
			thrust::raw_pointer_cast( dOutPoints.data() ) ,
			thrust::raw_pointer_cast( dPointsToLeafs.data() ) ,
			thrust::raw_pointer_cast( dPointMap.data() ) , aPoints.size() ,
			rootX , rootY , rootSize ,
			thrust::raw_pointer_cast( dQuadNodes.data() )
			);
		copy( aPoints , dOutPoints );
	}
	//copy the tree to the host for debug usage
	out_aQuadNode.resize( dQuadNodes.size() );
	thrust::copy( dQuadNodes.begin() , dQuadNodes.end() , out_aQuadNode.begin() );
	//out_aQuadNode = dQuadNodes;

	//thrust::host_vector< int > counters = dCounters;
	/*thrust::device_vector< vec2 > dnPositions;
	dnPositions.reserve( positions.size() );
	kPack << < dim3( ( posN + 31 ) / 32 ) , dim3( 32 , 1 , 1 ) >> > (
		thrust::raw_pointer_cast< float* >( &dPositions[ 0 ] ) ,
		positions.size() ,
		thrust::raw_pointer_cast< float* >( &dnPositions[ 0 ] )
		);*/
}