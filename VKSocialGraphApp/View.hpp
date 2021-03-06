#pragma once
#include <malloc.h>
#include <string.h>
#include <stdlib.h>
#include <stdint.h>
#include "DataStruct.hpp"
#define _USE_MATH_DEFINES
#include <math.h>
#include "Atlas.hpp"
#include <qvector.h>
#include <CudaModule/CudaModule.h>
struct SpatialState
{
	float x , y;
	uint8_t u , v , u_size , v_size;
};
struct RectData
{
	float x , y , scale;
	uint8_t u , v , u_size , v_size;
};
static inline float unirandf()
{
	return float( rand() ) / RAND_MAX;
}
struct View
{
	struct Rects
	{
		Program program;
		Buffer dev_buffer , quad_buffer;
		uint32_t vao , uviewproj , utexture , ucolor;
		void init()
		{
			glGenVertexArrays( 1 , &vao );
			glBindVertexArray( vao );
			dev_buffer = Buffer::createVBO( GL_STREAM_DRAW ,
			{ 3 ,
			{
				{ 1 , 2 , GL_FLOAT , GL_FALSE , 16 , 0 , 1 },
				{ 2 , 1 , GL_FLOAT , GL_FALSE , 16 , 8 , 1 },
				{ 3 , 4 , GL_UNSIGNED_BYTE , GL_TRUE , 16 , 12 , 1 }
			}
			} );
			dev_buffer.bind();
			quad_buffer = Buffer::createVBO( GL_STATIC_DRAW ,
			{ 1 ,
			{
				{ 0 , 2 , GL_FLOAT , GL_FALSE , 8 , 0 , 0 },
			}
			} );
			quad_buffer.bind();
			float rect_coords[] =
			{
				-1.0f , -1.0f ,
				-1.0f , 1.0f ,
				1.0f , 1.0f ,
				-1.0f , -1.0f ,
				1.0f , 1.0f ,
				1.0f , -1.0f
			};
			quad_buffer.setData( rect_coords , sizeof( rect_coords ) );
			glBindVertexArray( 0 );
			program.init(
				"#version 430 core\n\
				uniform vec4 color;\n\
				uniform sampler2D texture;\n\
				in vec4 uv;\n\
				void main()\n\
				{\n\
					float alpha = length( uv.zw - 0.5 ) < 0.5 ? 1.0 : 0.0;\n\
					gl_FragColor = color * texture2D( texture , uv.xy ) * vec4( 1.0 , 1.0 , 1.0 , alpha );\n\
				}"
				,
				"#version 430 core\n\
				uniform mat4 viewproj;\n\
				layout (location = 0) in vec2 position;\n\
				layout (location = 1) in vec2 offset;\n\
				layout (location = 2) in float scale;\n\
				layout (location = 3) in vec4 vertex_uv;\n\
				flat out int InstanceID;\n\
				out vec4 uv;\n\
				void main()\n\
				{\n\
					uv.xy = ( position * 0.5 + 0.5 ) * vertex_uv.zw + vertex_uv.xy;\n\
					uv.zw = position * 0.5 + 0.5;\n\
					InstanceID = gl_InstanceID;\n\
					gl_Position = viewproj * vec4( position * scale + offset , 0.0 , 1.0 );\n\
				}"
			);
			uviewproj = program.getUniform( "viewproj" );
			ucolor = program.getUniform( "color" );
			utexture = program.getUniform( "texture" );
		}
		void update( QVector< SpatialState > const &sstates )
		{
			float view_size = 1.1f;
			dev_buffer.resize( sstates.size() * sizeof( RectData ) );
			Buffer::Mapping< RectData > rects( dev_buffer , true );
			int i = 0;
			for( auto const &sstate : sstates )
			{
				RectData rect =
				{
					sstate.x , sstate.y , view_size , sstate.u , sstate.v , sstate.u_size , sstate.v_size
				};
				rects.add( rect );
			}
		}
		void draw( QVector< SpatialState > const &sstates , float *viewproj )
		{
			program.bind();
			glUniform4f( ucolor , 1.0f , 1.0f , 1.0f , 1.0f );
			glUniform1i( utexture , 0 );
			glUniformMatrix4fv( uviewproj , 1 , false , viewproj );
			dev_buffer.bindRaw();
			update( sstates );
			glBindVertexArray( vao );
			glDrawArraysInstanced( GL_TRIANGLES , 0 , 6 , sstates.size() );
			glBindVertexArray( 0 );
		}
	} rects;
	struct
	{
		Program program;
		Buffer dev_buffer;
		uint32_t uviewproj , ucolor;
		uint32_t vao;
		void init()
		{
			glGenVertexArrays( 1 , &vao );
			glBindVertexArray( vao );
			dev_buffer = Buffer::createVBO( GL_STREAM_DRAW , { 1 ,{ { 0 , 2 , GL_FLOAT , false , 8,0 } } } );
			dev_buffer.bind();
			glBindVertexArray( 0 );
			program.init(
				"precision highp float;\n\
				uniform vec4 color;\n\
				void main()\n\
				{\n\
					gl_FragColor = color;\n\
				}"
				,
				"uniform mat4 viewproj;\n\
				attribute vec2 position;\n\
				void main()\n\
				{\n\
					gl_Position = viewproj * vec4( position , 0.0 , 1.0 );\n\
				}"
			);
			uviewproj = program.getUniform( "viewproj" );
			ucolor = program.getUniform( "color" );
		}
		void update( QVector< SpatialState > const &sstates ,
			QVector< QPair< uint32_t , uint32_t > > const &relations )
		{
			dev_buffer.resize( relations.size() * 16 );
			Buffer::Mapping< float > lines( dev_buffer , true );
			int i = 0;
			for( auto const &relation : relations )
			{
				if( relation.first >= sstates.size() || relation.second >= sstates.size() )
				{
					continue;
				}
				auto v0 = sstates[ relation.first ];
				auto v1 = sstates[ relation.second ];
				lines
					.add( v0.x )
					.add( v0.y )
					.add( v1.x )
					.add( v1.y );
			}
		}
		void draw( QVector< SpatialState > const &sstates ,
			QVector< QPair< uint32_t , uint32_t > > const &relations , float *viewproj )
		{
			if( relations.size() == 0 )
			{
				return;
			}
			dev_buffer.bind();
			update( sstates , relations );
			glBindVertexArray( vao );
			program.bind();
			glUniform4f( ucolor , 0.0f , 0.0f , 0.0f , 1.0f );
			glUniformMatrix4fv( uviewproj , 1 , false , viewproj );
			glDrawArrays( GL_LINES , 0 , relations.size() * 2 );
			glBindVertexArray( 0 );
		}
		void fillCell( std::vector< QuadNode > const &aQuadNodes ,
			Buffer::Mapping< float > &lines ,
			float cellX , float cellY , float cellSize , int i )
		{
			auto node = aQuadNodes[ i ];
			lines.add( cellX - cellSize ).add( cellY - cellSize ).add( cellX - cellSize ).add( cellY + cellSize );
			lines.add( cellX - cellSize ).add( cellY + cellSize ).add( cellX + cellSize ).add( cellY + cellSize );
			lines.add( cellX + cellSize ).add( cellY + cellSize ).add( cellX + cellSize ).add( cellY - cellSize );
			lines.add( cellX + cellSize ).add( cellY - cellSize ).add( cellX - cellSize ).add( cellY - cellSize );
			if( node.children[ 0 ] > 0 )
			{
				for( int j = 0; j < 4; j++ )
				{
					auto childPosition = getChildPosition( cellX , cellY , cellSize , j );
					fillCell( aQuadNodes , lines ,
						childPosition.x , childPosition.y , cellSize / 2 , node.children[ j ] );
				}
			}
		};
		void drawQuadNodes( QVector< SpatialState > const &sstates ,
			std::vector< QuadNode > const &aQuadNodes , float *viewproj )
		{
			if( aQuadNodes.size() == 0 )
			{
				return;
			}
			float max_x = 0.0f , min_x = 0.0f , max_y = 0.0f , min_y = 0.0f;
			for( auto const &pos : sstates )
			{
				max_x = fmaxf( max_x , pos.x );
				min_x = fminf( min_x , pos.x );
				max_y = fmaxf( max_y , pos.y );
				min_y = fminf( min_y , pos.y );
			}
			float rootX = ( max_x + min_x ) * 0.5f;
			float rootY = ( max_y + min_y ) * 0.5f;
			float rootSize = 2.0f + fmaxf( ( max_x - min_x ) * 0.5f , ( max_y - min_y ) * 0.5f );
			{
				dev_buffer.bind();
				dev_buffer.resize( aQuadNodes.size() * 8 * 2 * 4 );
				Buffer::Mapping< float > lines( dev_buffer , true );
				fillCell( aQuadNodes , lines , rootX , rootY , rootSize , 0 );
			}
			glBindVertexArray( vao );
			program.bind();
			glUniform4f( ucolor , 1.0f , 0.0f , 0.0f , 1.0f );
			glUniformMatrix4fv( uviewproj , 1 , false , viewproj );
			glDrawArrays( GL_LINES , 0 , aQuadNodes.size() * 8 );
			glBindVertexArray( 0 );
		}
	} edges;
	void init()
	{
		rects.init();
		edges.init();
	}
	View() = default;
	void render( QVector< SpatialState > const &sstates ,
		QVector< QPair< uint32_t , uint32_t > > const &relations ,
		std::vector< QuadNode > const &aQuadNodes ,
		float x , float y , float z , int width , int height )
	{
		if( sstates.size() == 0 )
		{
			return;
		}
		float viewproj[] =
		{
			-1.0f , 0.0f , 0.0f , 0.0f ,
			0.0f , float( width ) / height , 0.0f , 0.0f ,
			0.0f , 0.0f , 1.0f , 0.0f ,
			x , -y , 0.0f , z
		};
		
		edges.draw( sstates , relations , viewproj );
		rects.draw( sstates , viewproj );
		edges.drawQuadNodes( sstates , aQuadNodes , viewproj );

	}
};